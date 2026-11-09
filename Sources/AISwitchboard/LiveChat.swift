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

    let chatID: String
    let directory: String
    let fileURL: URL
    /// Size of the transcript when the current turn started: the history is read up to here
    /// while the turn is shown live.
    private(set) var historyCutoff: Int?
    /// A chat that doesn't exist yet: the first process creates it with this id.
    var isNew = false

    @Published private(set) var items: [Item] = []
    @Published private(set) var isRunning = false
    @Published private(set) var pendingPermission: Permission?
    /// Context Claude rereads on the next turn, from the latest answer's usage.
    @Published private(set) var contextTokens = 0
    @Published var account: ClaudeAccount?
    @Published var model: String?
    @Published var mode: PermissionMode = .manual {
        didSet {
            // Claude Code switches mode on the fly: no need to restart it.
            guard mode != oldValue, process?.isRunning == true else { return }
            write(["type": "control_request", "request_id": UUID().uuidString,
                   "request": ["subtype": "set_permission_mode", "mode": mode.rawValue]])
            startedWith?.mode = mode
        }
    }
    private var stopRequested = false

    /// Called when a turn ends, so the transcript and the indexes can be refreshed.
    var onTurnFinished: (() -> Void)?
    var onRateLimit: (([String: Any]) -> Void)?

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var startedWith: (account: String?, model: String?, mode: PermissionMode)?
    /// Index in `items` of the text block being streamed, by content-block index.
    private var streaming: [Int: Int] = [:]

    init(chatID: String, directory: String, fileURL: URL) {
        self.chatID = chatID
        self.directory = directory
        self.fileURL = fileURL
    }

    // MARK: - Sending

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning else { return }
        do {
            try ensureProcess()
        } catch {
            items.append(.notice(id: UUID().uuidString, text: "Non riesco ad avviare Claude: \(error.localizedDescription)", isError: true))
            return
        }
        items.append(.user(id: UUID().uuidString, text: trimmed))
        historyCutoff = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? nil
        isRunning = true
        write(["type": "user", "message": ["role": "user", "content": trimmed]])
    }

    func stop() {
        guard isRunning else { return }
        stopRequested = true
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
        let wanted = (account: account?.id, model: model, mode: mode)
        if process?.isRunning == true, let started = startedWith,
           started.account == wanted.account, started.model == wanted.model, started.mode == wanted.mode {
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
        ]
        if let model { arguments += ["--model", model] }
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
        if isRunning {
            let message = errors.trimmingCharacters(in: .whitespacesAndNewlines)
            finishTurn(notice: message.isEmpty ? "Claude si è fermato" : "Claude si è fermato: \(message.prefix(300))", isError: true)
        }
    }

    // MARK: - Events

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
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
        switch event["type"] as? String {
        case "stream_event":
            guard event["parent_tool_use_id"] is NSNull || event["parent_tool_use_id"] == nil,
                  let inner = event["event"] as? [String: Any] else { return }
            handleStream(inner)
        case "assistant":
            guard event["parent_tool_use_id"] is NSNull || event["parent_tool_use_id"] == nil,
                  let message = event["message"] as? [String: Any] else { return }
            if let usage = message["usage"] as? [String: Any] {
                let tokens = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
                    .reduce(0) { $0 + ((usage[$1] as? NSNumber)?.intValue ?? 0) }
                if tokens > 0 { contextTokens = tokens }
            }
            for block in message["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "tool_use" {
                guard let id = block["id"] as? String, !items.contains(where: { $0.id == id }) else { continue }
                let name = block["name"] as? String ?? "tool"
                items.append(.tool(Tool(id: id, name: name, summary: Self.summary(name: name, input: block["input"] as? [String: Any] ?? [:]))))
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
            // Tests: `-debugAutoAllow YES` answers through the same path as the “Consenti” button.
            if UserDefaults.standard.bool(forKey: "debugAutoAllow"), let permission = pendingPermission {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.answer(permission, allow: true) }
            }
        case "rate_limit_event":
            if let info = event["rate_limit_info"] as? [String: Any] { onRateLimit?(info) }
        case "result":
            if stopRequested {
                finishTurn(notice: "Interrotto")
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
        case "content_block_start":
            let block = event["content_block"] as? [String: Any] ?? [:]
            switch block["type"] as? String {
            case "text":
                items.append(.text(id: UUID().uuidString, text: block["text"] as? String ?? ""))
                streaming[index] = items.count - 1
            case "thinking", "redacted_thinking":
                items.append(.thinking(id: UUID().uuidString))
                streaming[index] = items.count - 1
            default:
                break
            }
        case "content_block_delta":
            guard let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                  let position = streaming[index], items.indices.contains(position),
                  case .text(let id, let text) = items[position] else { return }
            items[position] = .text(id: id, text: text + (delta["text"] as? String ?? ""))
        case "content_block_stop":
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
        stopRequested = false
        onTurnFinished?()
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
            if path.hasSuffix("/claude") || path.contains("/claude/") { kill(pid, SIGTERM) }
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
