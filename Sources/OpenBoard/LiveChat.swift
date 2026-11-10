import Foundation
import Darwin
import SwiftUI

/// A conversation with Claude Code run from inside the app, like OpenChamber does with OpenCode.
///
/// Claude Code runs headless (`-p`) with stream-json on both sides and stays alive between
/// turns. Permission prompts come back to the app (`--permission-prompts host` with the stdio
/// prompt tool): each one is shown as a card and answered with allow or deny. The conversation
/// is the same transcript: it is resumed with `--resume` and keeps growing in the same file,
/// so Warp and `/resume` see everything written here.
@MainActor
final class LiveChat: ObservableObject {
    enum PermissionMode: String, CaseIterable, Identifiable {
        case manual, acceptEdits, plan, bypassPermissions
        var id: String { rawValue }
        var title: String {
            switch self {
            case .manual: return "Chiedi"
            case .acceptEdits: return "Accetta modifiche"
            case .plan: return "Solo piano"
            case .bypassPermissions: return "Tutto senza chiedere"
            }
        }
        var detail: String {
            switch self {
            case .manual: return "Claude chiede prima di modificare file o eseguire comandi"
            case .acceptEdits: return "Le modifiche ai file passano da sole, i comandi chiedono"
            case .plan: return "Claude legge e propone un piano, non cambia niente"
            case .bypassPermissions: return "Nessuna domanda: usalo solo in cartelle di cui ti fidi"
            }
        }
    }

    struct Tool: Identifiable {
        let id: String
        let name: String
        let summary: String
        var result: String?
        var isError = false
        var isDone: Bool { result != nil }
    }

    struct Permission: Identifiable {
        let id: String
        let tool: String
        let summary: String
        let input: [String: Any]
        let canAllowEdits: Bool
    }

    enum Item: Identifiable {
        case user(id: String, text: String)
        case text(id: String, text: String)
        case thinking(id: String)
        case tool(Tool)
        case notice(id: String, text: String, isError: Bool)

        var id: String {
            switch self {
            case .user(let id, _), .text(let id, _), .thinking(let id), .notice(let id, _, _): return id
            case .tool(let tool): return tool.id
            }
        }
    }

    /// Codex only learns its id when the first turn starts: then this becomes the real one.
    private(set) var chatID: String
    let directory: String
    let fileURL: URL
    let provider: Provider
    /// Codex: sandbox for the commands it runs (it has no interactive permission prompts).
    @Published var sandbox: CodexSandbox = .workspaceWrite
    var onThreadStarted: ((String) -> Void)?
    /// Size of the transcript when the current turn started: the history is read up to here
    /// while the turn is shown live.
    private(set) var historyCutoff: Int?
    /// A chat that doesn't exist yet: the first process creates it with this id.
    var isNew = false

    @Published private(set) var items: [Item] = []
    @Published private(set) var isRunning = false {
        didSet {
            guard isRunning != oldValue else { return }
            turnStartedAt = isRunning ? Date() : nil
            activity = isRunning ? "Pensa" : nil
            thinkingText = ""
            if isRunning { turnOutputTokens = 0; outputBase = 0; streamingTools.removeAll() }
            if isRunning { startWatchdog() } else { stopWatchdog() }
            onStateChange?()
        }
    }
    /// Set when a running turn has gone fully silent (no stdout at all, not even a tool
    /// starting) for a while: the underlying `claude`/`codex` process is most likely stuck on
    /// something (seen once with a plain `ls | grep` that never returned). The stop button
    /// already exists; this just makes a silent hang visible instead of an endless spinner.
    @Published private(set) var stalledSince: Date?
    private var lastActivityAt: Date?
    private var watchdog: Timer?
    private static let stallThreshold: TimeInterval = 90
    @Published private(set) var pendingPermission: Permission? {
        didSet { if (pendingPermission == nil) != (oldValue == nil) { onStateChange?() } }
    }
    /// When the running turn started, for the elapsed time in the sidebar.
    private(set) var turnStartedAt: Date?
    /// Extra instructions given to Claude at start (`--append-system-prompt`): the project's
    /// milestones, the orchestrator's or agent's role. Read when Claude starts; when they change,
    /// the next message starts Claude again with the new ones.
    var systemPromptProvider: (() -> String?)?
    /// Called when the chat starts or ends a turn, or starts or stops waiting for a permission.
    var onStateChange: (() -> Void)?
    /// Context Claude rereads on the next turn, from the latest answer's usage.
    @Published private(set) var contextTokens = 0
    @Published var account: ClaudeAccount?
    @Published var model: String?
    @Published var mode: PermissionMode = .manual {
        didSet {
            // Claude Code switches mode on the fly: no need to restart it.
            guard mode != oldValue, process?.isRunning == true else { return }
            let requestID = UUID().uuidString
            modeRequests.insert(requestID)
            write(["type": "control_request", "request_id": requestID,
                   "request": ["subtype": "set_permission_mode", "mode": mode.rawValue]])
            startedWith?.mode = mode
        }
    }
    private var stopRequested = false
    /// Mode switches sent to Claude: if one is refused, the next message restarts it in that mode.
    private var modeRequests: Set<String> = []

    // MARK: - What Claude is doing (status line, like the terminal)

    /// The current step in words: "Pensa", "Esegue `npm test`", "Legge Package.swift"…
    @Published private(set) var activity: String?
    /// The reasoning streamed while Claude thinks (dropped when the block ends).
    @Published private(set) var thinkingText = ""
    /// Tokens Claude has written in this turn.
    @Published private(set) var turnOutputTokens = 0
    private var outputBase = 0
    /// Tool calls being streamed, by content-block index: their input arrives in pieces.
    private var streamingTools: [Int: (id: String, name: String, json: String)] = [:]

    /// A tool call started and not answered yet (a long command, a sub-agent…).
    var hasRunningTool: Bool {
        items.contains { if case .tool(let tool) = $0 { return !tool.isDone } else { return false } }
    }

    static func activityLabel(name: String, input: [String: Any]) -> String {
        let detail = summary(name: name, input: input)
        let file = (input["file_path"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
        switch name {
        case "Bash": return detail.isEmpty ? "Esegue un comando" : "Esegue `\(detail.prefix(70))`"
        case "BashOutput": return "Legge l'output di un comando"
        case "Read", "NotebookRead": return "Legge \(file ?? detail)"
        case "Edit", "MultiEdit", "NotebookEdit": return "Modifica \(file ?? detail)"
        case "Write": return "Scrive \(file ?? detail)"
        case "Grep", "Glob", "LS": return detail.isEmpty ? "Cerca nei file" : "Cerca \(detail.prefix(60))"
        case "WebFetch": return "Apre \(detail.prefix(60))"
        case "WebSearch": return "Cerca sul web \(detail.prefix(60))"
        case "Task", "Agent": return "Fa lavorare un agente: \(detail.prefix(60))"
        case "TodoWrite": return "Aggiorna la lista delle cose da fare"
        case "ToolSearch": return "Cerca uno strumento"
        default:
            let tool = name.hasPrefix("mcp__") ? name.split(separator: "_").last.map(String.init) ?? name : name
            return detail.isEmpty ? "Usa \(tool)" : "Usa \(tool): \(detail.prefix(60))"
        }
    }

    /// Called when a turn ends, so the transcript and the indexes can be refreshed.
    var onTurnFinished: (() -> Void)?
    var onRateLimit: (([String: Any]) -> Void)?
    var onPermission: ((Permission) -> Void)?
    /// Claude: an account with room left when the current one is at its limit, or nil.
    var betterAccount: ((ClaudeAccount?) -> ClaudeAccount?)?
    private var switchedForLimit = false

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var startedWith: (account: String?, model: String?, mode: PermissionMode, prompt: String?)?
    /// Index in `items` of the text block being streamed, by content-block index.
    private var streaming: [Int: Int] = [:]

    init(chatID: String, directory: String, fileURL: URL, provider: Provider = .claude) {
        self.chatID = chatID
        self.directory = directory
        self.fileURL = fileURL
        self.provider = provider
    }

    // MARK: - Sending

    /// Messages written while Claude was busy: sent one after the other as turns end.
    struct Queued: Identifiable {
        let id = UUID()
        let text: String
        let attachments: [URL]
    }
    @Published private(set) var queue: [Queued] = []
    /// The last message sent, kept to send it again with another account at the usage limit.
    private(set) var lastSent: Queued?

    func removeFromQueue(_ id: UUID) { queue.removeAll { $0.id == id } }

    /// What Claude wrote in the turn just finished (or running): its text after the last prompt.
    var lastTurnText: String {
        let start = (items.lastIndex { if case .user = $0 { return true } else { return false } }).map { $0 + 1 } ?? 0
        return items[start...].compactMap { item -> String? in
            if case .text(_, let text) = item { return text }
            return nil
        }.joined(separator: "\n\n")
    }

    /// The error that ended the last turn, if it ended with one.
    var lastTurnError: String? {
        if case .notice(_, let text, true) = items.last { return text }
        return nil
    }

    func send(_ text: String, attachments: [URL] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        if isRunning {
            queue.append(Queued(text: trimmed, attachments: attachments))
            return
        }
        lastSent = Queued(text: trimmed, attachments: attachments)
        if provider == .codex { sendCodex(trimmed, attachments: attachments); return }
        if let better = betterAccount?(account), better.id != account?.id {
            items.append(.notice(id: UUID().uuidString, text: "\(account?.name ?? "L'account") è al limite: passo a \(better.name)", isError: false))
            account = better
        }
        do {
            try ensureProcess()
        } catch {
            items.append(.notice(id: UUID().uuidString, text: "Non riesco ad avviare Claude: \(error.localizedDescription)", isError: true))
            return
        }
        items.append(.user(id: UUID().uuidString, text: Self.shown(trimmed, attachments)))
        historyCutoff = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? nil
        isRunning = true
        write(["type": "user", "message": ["role": "user", "content": Self.contentBlocks(trimmed, attachments)]])
    }

    /// Images go in as image blocks; other files are named by path so Claude can read them.
    static func contentBlocks(_ text: String, _ attachments: [URL]) -> Any {
        guard !attachments.isEmpty else { return text }
        var blocks: [[String: Any]] = []
        var files: [String] = []
        for url in attachments {
            if let type = imageType(url), let data = try? Data(contentsOf: url), data.count < 15_000_000 {
                blocks.append(["type": "image", "source": ["type": "base64", "media_type": type, "data": data.base64EncodedString()]])
            } else {
                files.append(url.path)
            }
        }
        var body = text
        if !files.isEmpty { body += (body.isEmpty ? "" : "\n\n") + "File allegati:\n" + files.map { "- \($0)" }.joined(separator: "\n") }
        if !body.isEmpty { blocks.insert(["type": "text", "text": body], at: 0) }
        return blocks
    }

    nonisolated static func isLimitError(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["usage limit", "rate limit", "limit reached", "limite di utilizzo", "out of extra usage", "quota"].contains { lower.contains($0) }
    }

    static func imageType(_ url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return nil
        }
    }

    static func shown(_ text: String, _ attachments: [URL]) -> String {
        attachments.isEmpty ? text : text + (text.isEmpty ? "" : "\n") + attachments.map { "📎 \($0.lastPathComponent)" }.joined(separator: "  ")
    }

    private func startWatchdog() {
        lastActivityAt = Date()
        stalledSince = nil
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkStalled() }
        }
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
        stalledSince = nil
    }

    private func checkStalled() {
        guard isRunning, stalledSince == nil, let lastActivityAt else { return }
        // A command or a sub-agent at work prints nothing until it ends: give it much longer.
        let threshold = hasRunningTool ? 15 * 60 : Self.stallThreshold
        if Date().timeIntervalSince(lastActivityAt) >= threshold { stalledSince = Date() }
    }

    func stop() {
        guard isRunning else { return }
        stopRequested = true
        if provider == .codex { process?.interrupt(); return }
        write(["type": "control_request", "request_id": UUID().uuidString, "request": ["subtype": "interrupt"]])
        if let pending = pendingPermission { answer(pending, allow: false) }
        // If it doesn't stop by itself, the process goes; the next message starts a new one.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.isRunning else { return }
            self.terminate()
            self.finishTurn(notice: "Interrotto")
        }
    }

    func answer(_ permission: Permission, allow: Bool, allowEditsFromNow: Bool = false) {
        pendingPermission = nil
        let response: [String: Any] = allow
            ? ["behavior": "allow", "updatedInput": permission.input]
            : ["behavior": "deny", "message": "L'utente ha negato il permesso da OpenBoard."]
        write(["type": "control_response", "response": [
            "subtype": "success", "request_id": permission.id, "response": response,
        ]])
        if allowEditsFromNow { mode = .acceptEdits }
    }

    /// The Claude Code process of this chat, to tell it apart from sessions opened in a terminal.
    var pid: Int32? { process?.processIdentifier }

    func terminate() {
        if let pid = process?.processIdentifier { LiveChat.forget(pid) }
        process?.terminate()
        process = nil
        input = nil
        startedWith = nil
    }

    /// Items of finished turns are now in the transcript itself: drop them once it is reloaded.
    func clearFinishedTurns() {
        guard !isRunning else { return }
        historyCutoff = nil
        items.removeAll()
        streaming.removeAll()
    }

    // MARK: - Process

    private func ensureProcess() throws {
        let prompt = systemPromptProvider?()
        let wanted = (account: account?.id, model: model, mode: mode, prompt: prompt)
        if process?.isRunning == true, let started = startedWith,
           started.account == wanted.account, started.model == wanted.model, started.mode == wanted.mode,
           started.prompt == wanted.prompt {
            return
        }
        terminate()

        guard let binary = ClaudeAssistant.binaryPath else { throw ChatOperationError.io("Non trovo il comando claude") }
        var directoryIsFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &directoryIsFolder), directoryIsFolder.boolValue else {
            throw ChatOperationError.io("la cartella \(directory) non esiste più")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        var arguments = [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--include-partial-messages", isNew ? "--session-id" : "--resume", chatID,
            "--permission-mode", mode.rawValue,
            "--permission-prompts", "host", "--permission-prompt-tool", "stdio",
            // Lets "Tutto senza chiedere" be chosen after the start: without it Claude Code refuses
            // the switch and keeps asking. It only allows the mode, it doesn't turn it on.
            "--allow-dangerously-skip-permissions",
        ]
        if let model { arguments += ["--model", model] }
        if let prompt { arguments += ["--append-system-prompt", prompt] }
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        var environment = ProcessInfo.processInfo.environment
        if let account, !account.isDefault { environment["CLAUDE_CONFIG_DIR"] = account.configDir.path }
        process.environment = environment

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in self?.receive(data) }
        }
        process.terminationHandler = { [weak self] finished in
            let errors = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            Task { @MainActor in self?.ended(finished, errors: errors) }
        }
        try process.run()
        LiveChat.remember(process.processIdentifier)
        isNew = false
        self.process = process
        self.input = stdin.fileHandleForWriting
        self.startedWith = wanted
        write(["type": "control_request", "request_id": UUID().uuidString, "request": ["subtype": "initialize"]])
    }

    private func write(_ object: [String: Any]) {
        guard let input, var data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        try? input.write(contentsOf: data)
    }

    private func ended(_ finished: Process, errors: String) {
        guard finished === process || process == nil else { return }
        process = nil
        input = nil
        startedWith = nil
        if isRunning, provider == .codex {
            // A Codex turn is one process: its exit ends the turn if turn.completed didn't.
            let message = errors.trimmingCharacters(in: .whitespacesAndNewlines)
            finishTurn(notice: stopRequested ? "Interrotto" : (message.isEmpty ? nil : "Codex: \(message.suffix(300))"),
                       isError: !stopRequested && !message.isEmpty)
            return
        }
        if isRunning {
            let message = errors.trimmingCharacters(in: .whitespacesAndNewlines)
            finishTurn(notice: message.isEmpty ? "Claude si è fermato" : "Claude si è fermato: \(message.prefix(300))", isError: true)
        }
    }

    // MARK: - Events

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        lastActivityAt = Date()
        stalledSince = nil
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty,
                  let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            handle(event)
        }
    }

    private func handle(_ event: [String: Any]) {
        if provider == .codex { handleCodex(event); return }
        switch event["type"] as? String {
        case "control_response":
            guard let response = event["response"] as? [String: Any], let id = response["request_id"] as? String,
                  modeRequests.remove(id) != nil, response["subtype"] as? String == "error" else { return }
            // Refused: Claude stays in the old mode. The next message starts it again in the chosen one.
            startedWith = nil
            items.append(.notice(id: UUID().uuidString, text: "La modalità “\(mode.title)” vale dal prossimo messaggio", isError: false))
        case "stream_event":
            guard event["parent_tool_use_id"] is NSNull || event["parent_tool_use_id"] == nil,
                  let inner = event["event"] as? [String: Any] else { return }
            handleStream(inner)
        case "assistant":
            if !(event["parent_tool_use_id"] is NSNull || event["parent_tool_use_id"] == nil) {
                // A sub-agent at work: show its step.
                let blocks = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                if let use = blocks.last(where: { $0["type"] as? String == "tool_use" }) {
                    activity = "Agente · " + Self.activityLabel(name: use["name"] as? String ?? "", input: use["input"] as? [String: Any] ?? [:])
                }
                return
            }
            guard let message = event["message"] as? [String: Any] else { return }
            if let usage = message["usage"] as? [String: Any] {
                let tokens = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
                    .reduce(0) { $0 + ((usage[$1] as? NSNumber)?.intValue ?? 0) }
                if tokens > 0 { contextTokens = tokens }
            }
            for block in message["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "tool_use" {
                guard let id = block["id"] as? String else { continue }
                let name = block["name"] as? String ?? "tool"
                let summary = Self.summary(name: name, input: block["input"] as? [String: Any] ?? [:])
                if let index = items.firstIndex(where: { $0.id == id }) {
                    // Already shown while streaming: complete its description.
                    if case .tool(var tool) = items[index], tool.summary.isEmpty {
                        tool = Tool(id: tool.id, name: tool.name, summary: summary, result: tool.result, isError: tool.isError)
                        items[index] = .tool(tool)
                    }
                } else {
                    items.append(.tool(Tool(id: id, name: name, summary: summary)))
                }
            }
        case "user":
            guard let message = event["message"] as? [String: Any] else { return }
            for block in message["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "tool_result" {
                guard let id = block["tool_use_id"] as? String,
                      let index = items.firstIndex(where: { $0.id == id }),
                      case .tool(var tool) = items[index] else { continue }
                tool.result = Self.text(of: block["content"])
                tool.isError = block["is_error"] as? Bool == true
                items[index] = .tool(tool)
                if !hasRunningTool { activity = "Pensa" }
            }
        case "control_request":
            guard let request = event["request"] as? [String: Any],
                  request["subtype"] as? String == "can_use_tool",
                  let id = event["request_id"] as? String else { return }
            let name = request["tool_name"] as? String ?? "tool"
            let input = request["input"] as? [String: Any] ?? [:]
            let suggestions = request["permission_suggestions"] as? [[String: Any]] ?? []
            pendingPermission = Permission(
                id: id, tool: name,
                summary: (request["description"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? Self.summary(name: name, input: input),
                input: input,
                canAllowEdits: suggestions.contains { $0["mode"] as? String == "acceptEdits" }
            )
            if let permission = pendingPermission { onPermission?(permission) }
            // Tests: `-debugAutoAllow YES` answers through the same path as the “Consenti” button.
            if UserDefaults.standard.bool(forKey: "debugAutoAllow"), let permission = pendingPermission {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.answer(permission, allow: true) }
            }
        case "rate_limit_event":
            if let info = event["rate_limit_info"] as? [String: Any] { onRateLimit?(info) }
        case "result":
            if stopRequested {
                finishTurn(notice: "Interrotto")
            } else if event["is_error"] as? Bool == true, Self.isLimitError(event["result"] as? String ?? ""),
                      !switchedForLimit, let better = betterAccount?(account), better.id != account?.id, let last = lastSent {
                // Out of quota mid-chat: same conversation, other account, same message again.
                switchedForLimit = true
                items.append(.notice(id: UUID().uuidString, text: "\(account?.name ?? "L'account") ha finito il limite: riprovo con \(better.name)", isError: false))
                account = better
                isRunning = false
                pendingPermission = nil
                send(last.text, attachments: last.attachments)
                return
            } else {
                let isError = event["is_error"] as? Bool == true
                finishTurn(notice: isError ? (event["result"] as? String ?? "Errore durante la risposta") : nil, isError: isError)
            }
        default:
            break
        }
    }

    private func handleStream(_ event: [String: Any]) {
        let index = (event["index"] as? NSNumber)?.intValue ?? 0
        switch event["type"] as? String {
        case "message_start":
            streaming.removeAll()
            streamingTools.removeAll()
            outputBase = turnOutputTokens
        case "message_delta":
            if let usage = event["usage"] as? [String: Any], let output = (usage["output_tokens"] as? NSNumber)?.intValue {
                turnOutputTokens = outputBase + output
            }
        case "content_block_start":
            let block = event["content_block"] as? [String: Any] ?? [:]
            switch block["type"] as? String {
            case "text":
                items.append(.text(id: UUID().uuidString, text: block["text"] as? String ?? ""))
                streaming[index] = items.count - 1
            case "thinking", "redacted_thinking":
                items.append(.thinking(id: UUID().uuidString))
                streaming[index] = items.count - 1
                thinkingText = ""
                activity = "Pensa"
            case "tool_use":
                // Shown as soon as Claude starts writing the call, not when the message ends.
                guard let id = block["id"] as? String else { break }
                let name = block["name"] as? String ?? "tool"
                if !items.contains(where: { $0.id == id }) { items.append(.tool(Tool(id: id, name: name, summary: ""))) }
                streamingTools[index] = (id, name, "")
                activity = Self.activityLabel(name: name, input: [:])
            default:
                break
            }
        case "content_block_delta":
            guard let delta = event["delta"] as? [String: Any] else { return }
            switch delta["type"] as? String {
            case "thinking_delta":
                thinkingText += delta["thinking"] as? String ?? ""
            case "input_json_delta":
                streamingTools[index]?.json += delta["partial_json"] as? String ?? ""
            case "text_delta":
                guard let position = streaming[index], items.indices.contains(position),
                      case .text(let id, let text) = items[position] else { return }
                items[position] = .text(id: id, text: text + (delta["text"] as? String ?? ""))
                activity = "Scrive la risposta"
            default:
                break
            }
        case "content_block_stop":
            if let call = streamingTools.removeValue(forKey: index) {
                let input = (try? JSONSerialization.jsonObject(with: Data(call.json.utf8))) as? [String: Any] ?? [:]
                activity = Self.activityLabel(name: call.name, input: input)
                if let position = items.firstIndex(where: { $0.id == call.id }), case .tool(let tool) = items[position], tool.summary.isEmpty {
                    items[position] = .tool(Tool(id: tool.id, name: tool.name, summary: Self.summary(name: call.name, input: input),
                                                 result: tool.result, isError: tool.isError))
                }
            }
            // A finished thinking block is not kept: only the answer matters in the chat.
            if let position = streaming[index], items.indices.contains(position), case .thinking = items[position] {
                items.remove(at: position)
                streaming = streaming.mapValues { $0 > position ? $0 - 1 : $0 }
            }
            streaming[index] = nil
        default:
            break
        }
    }

    private func finishTurn(notice: String?, isError: Bool = false) {
        items.removeAll { if case .thinking = $0 { return true } else { return false } }
        if let notice { items.append(.notice(id: UUID().uuidString, text: notice, isError: isError)) }
        pendingPermission = nil
        isRunning = false
        switchedForLimit = false
        let stopped = stopRequested
        stopRequested = false
        onTurnFinished?()
        // Next queued message, unless the turn was stopped on purpose.
        if !stopped, !queue.isEmpty {
            let next = queue.removeFirst()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.send(next.text, attachments: next.attachments) }
        }
    }

    // MARK: - Codex

    enum CodexSandbox: String, CaseIterable, Identifiable {
        case readOnly = "read-only", workspaceWrite = "workspace-write", fullAccess = "danger-full-access"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .readOnly: return "Sola lettura"
            case .workspaceWrite: return "Scrive nella cartella"
            case .fullAccess: return "Accesso completo"
            }
        }
        var detail: String {
            switch self {
            case .readOnly: return "Codex legge e risponde, non cambia niente"
            case .workspaceWrite: return "Può modificare i file della cartella della chat, non il resto del Mac"
            case .fullAccess: return "Nessun limite: usalo solo se ti fidi del compito"
            }
        }
    }

    /// One `codex exec` per turn: a new thread the first time, `exec resume <id>` after.
    private func sendCodex(_ text: String, attachments: [URL] = []) {
        guard let binary = Codex.binaryPath else {
            items.append(.notice(id: UUID().uuidString, text: "Non trovo il comando codex", isError: true))
            return
        }
        var arguments: [String]
        if isNew {
            arguments = ["exec", "--json", "--skip-git-repo-check", "-s", sandbox.rawValue, "-C", directory]
        } else {
            arguments = ["exec", "resume", chatID, "--json", "--skip-git-repo-check", "-c", "sandbox_mode=\"\(sandbox.rawValue)\""]
        }
        if let model { arguments += ["-m", model] }
        let images = attachments.filter { Self.imageType($0) != nil }
        for image in images { arguments += ["-i", image.path] }
        // The prompt goes in on stdin: `-i` takes several values and would swallow it.
        let others = attachments.filter { Self.imageType($0) == nil }
        let prompt = text + (others.isEmpty ? "" : "\n\nFile allegati:\n" + others.map { "- \($0.path)" }.joined(separator: "\n"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let stdin = Pipe()
        process.standardInput = stdin
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in self?.receive(data) }
        }
        process.terminationHandler = { [weak self] finished in
            let errors = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            Task { @MainActor in self?.ended(finished, errors: errors) }
        }
        items.append(.user(id: UUID().uuidString, text: Self.shown(text, attachments)))
        historyCutoff = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? nil
        do {
            try process.run()
        } catch {
            items.append(.notice(id: UUID().uuidString, text: "Non riesco ad avviare Codex: \(error.localizedDescription)", isError: true))
            return
        }
        try? stdin.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
        try? stdin.fileHandleForWriting.close()
        LiveChat.remember(process.processIdentifier)
        self.process = process
        isRunning = true
    }

    private func handleCodex(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "thread.started":
            if let id = event["thread_id"] as? String, isNew {
                isNew = false
                let old = chatID
                chatID = id
                onThreadStarted?(old)
            }
        case "item.started", "item.updated", "item.completed":
            guard let item = event["item"] as? [String: Any], let id = item["id"] as? String else { return }
            let done = event["type"] as? String == "item.completed"
            switch item["type"] as? String {
            case "agent_message":
                guard done, let text = item["text"] as? String else { return }
                items.append(.text(id: "codex-\(id)-\(UUID().uuidString)", text: text))
            case "command_execution":
                let command = (item["command"] as? String ?? "").replacingOccurrences(of: "/bin/zsh -lc ", with: "")
                upsertTool(id: id, name: "Shell", summary: command, result: done ? (item["aggregated_output"] as? String ?? "") : nil,
                           isError: done && ((item["exit_code"] as? NSNumber)?.intValue ?? 0) != 0)
            case "file_change":
                let paths = (item["changes"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
                    .map { $0.replacingOccurrences(of: ClaudePaths.home.path, with: "~") }
                upsertTool(id: id, name: "Modifica", summary: paths.joined(separator: ", "),
                           result: done ? (item["status"] as? String ?? "") : nil, isError: done && item["status"] as? String == "failed")
            case "web_search":
                upsertTool(id: id, name: "Ricerca web", summary: item["query"] as? String ?? "", result: done ? "" : nil, isError: false)
            case "mcp_tool_call":
                upsertTool(id: id, name: item["tool"] as? String ?? "MCP", summary: item["server"] as? String ?? "", result: done ? "" : nil, isError: false)
            case "error":
                if done { items.append(.notice(id: UUID().uuidString, text: item["message"] as? String ?? "Errore", isError: true)) }
            default:
                break
            }
        case "turn.completed":
            if let usage = event["usage"] as? [String: Any], let input = (usage["input_tokens"] as? NSNumber)?.intValue {
                contextTokens = input
            }
            finishTurn(notice: nil)
        case "turn.failed", "error":
            let message = ((event["error"] as? [String: Any])?["message"] as? String) ?? event["message"] as? String ?? "Errore di Codex"
            finishTurn(notice: message, isError: true)
        default:
            break
        }
    }

    private func upsertTool(id: String, name: String, summary: String, result: String?, isError: Bool) {
        if let index = items.firstIndex(where: { $0.id == id }), case .tool(var tool) = items[index] {
            if let result { tool.result = result; tool.isError = isError }
            items[index] = .tool(tool)
        } else {
            items.append(.tool(Tool(id: id, name: name, summary: String(summary.prefix(160)), result: result, isError: isError)))
        }
    }

    // MARK: - Leftover processes

    /// Claude Code processes started by the app, so that ones left behind by a crash (still
    /// waiting on a permission prompt nobody will answer) can be closed at the next launch.
    private static var pidFile: URL { ClaudePaths.appSupport.appendingPathComponent("live-pids.json") }

    private static func pids() -> Set<Int32> {
        guard let data = try? Data(contentsOf: pidFile), let list = try? JSONDecoder().decode([Int32].self, from: data) else { return [] }
        return Set(list)
    }

    private static func save(_ pids: Set<Int32>) {
        if let data = try? JSONEncoder().encode(Array(pids)) { try? data.write(to: pidFile, options: .atomic) }
    }

    static func remember(_ pid: Int32) { save(pids().union([pid])) }
    static func forget(_ pid: Int32) { save(pids().subtracting([pid])) }

    /// Closes processes from an earlier run that are still alive and still Claude Code.
    static func closeLeftovers() {
        for pid in pids() {
            var buffer = [CChar](repeating: 0, count: 4096)
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            let path = length > 0 ? String(cString: buffer) : ""
            if path.hasSuffix("/claude") || path.contains("/claude/") || path.hasSuffix("/codex") || path.contains("/codex/") { kill(pid, SIGTERM) }
        }
        save([])
    }

    // MARK: - Text helpers

    static func summary(name: String, input: [String: Any]) -> String {
        let detail = (input["command"] as? String)
            ?? (input["file_path"] as? String).map { $0.replacingOccurrences(of: ClaudePaths.home.path, with: "~") }
            ?? (input["description"] as? String)
            ?? (input["pattern"] as? String)
            ?? (input["url"] as? String)
            ?? (input["query"] as? String)
            ?? ""
        return String(detail.replacingOccurrences(of: "\n", with: " ").prefix(160))
    }

    static func text(of content: Any?) -> String {
        if let string = content as? String { return string }
        let blocks = content as? [[String: Any]] ?? []
        return blocks.map { block in
            block["type"] as? String == "text" ? (block["text"] as? String ?? "") : "[\(block["type"] as? String ?? "contenuto")]"
        }.joined(separator: "\n")
    }
}

extension ClaudeAssistant {
    static var binaryPath: String? {
        ["~/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .map { NSString(string: $0).expandingTildeInPath }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
