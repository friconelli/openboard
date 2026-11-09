import Foundation

/// Which agent a chat belongs to.
enum Provider: String, Codable, CaseIterable, Identifiable {
    case claude, codex
    var id: String { rawValue }
    var title: String { self == .claude ? "Claude" : "Codex" }
    var symbol: String { self == .claude ? "sparkle" : "chevron.left.forwardslash.chevron.right" }
}

extension ChatSession {
    var isCodex: Bool { provider == .codex }
    var agent: Provider { provider ?? .claude }
}

/// Codex CLI sessions: `~/.codex/sessions/YYYY/MM/DD/rollout-…-<id>.jsonl`, titles in
/// `~/.codex/session_index.jsonl`. Read-only except for titles, which Codex itself keeps there.
enum Codex {
    static var home: URL { ClaudePaths.home.appendingPathComponent(".codex") }
    static var sessions: URL { home.appendingPathComponent("sessions") }
    static var index: URL { home.appendingPathComponent("session_index.jsonl") }

    static var binaryPath: String? {
        ["~/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
            .map { NSString(string: $0).expandingTildeInPath }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isInstalled: Bool { binaryPath != nil && FileManager.default.fileExists(atPath: sessions.path) }

    static func isCodexFile(_ url: URL) -> Bool { url.path.hasPrefix(sessions.path) }

    static func sessionFiles() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: sessions, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("rollout-") }
    }

    /// Latest title per thread id (the last line for an id wins).
    static func titles() -> [String: String] {
        guard let text = try? String(contentsOf: index, encoding: .utf8) else { return [:] }
        var titles: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let json = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let id = json["id"] as? String, let name = json["thread_name"] as? String else { continue }
            titles[id] = name
        }
        return titles
    }

    static func rename(_ id: String, to title: String) throws {
        let record: [String: Any] = ["id": id, "thread_name": title, "updated_at": isoFormatter.string(from: Date())]
        if !FileManager.default.fileExists(atPath: index.path) { FileManager.default.createFile(atPath: index.path, contents: nil) }
        try ChatOperations.append([record], to: index)
    }

    private static let userNeedle = Array(#""type":"UserMessage""#.utf8)
    private static let metaNeedle = Array(#""type":"session_meta""#.utf8)

    static func indexFile(_ file: URL, size: Int64, modified: Date, titles: [String: String]) -> ChatSession? {
        guard let data = try? Data(contentsOf: file, options: .alwaysMapped) else { return nil }
        var id: String?
        var cwd: String?
        var started: Date?
        var firstPrompt: String?
        var prompts = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            ChatIndexer.forEachLine(base: base, count: raw.count) { line, length in
                let isMeta = id == nil && ChatIndexer.contains(line, length, metaNeedle)
                let isUser = ChatIndexer.contains(line, length, userNeedle)
                guard isMeta || isUser,
                      let json = (try? JSONSerialization.jsonObject(with: Data(bytes: line, count: length))) as? [String: Any],
                      let payload = json["payload"] as? [String: Any] else { return }
                if isMeta {
                    id = payload["id"] as? String ?? payload["session_id"] as? String
                    cwd = payload["cwd"] as? String
                    started = (payload["timestamp"] as? String).flatMap { isoFormatter.date(from: $0) }
                    return
                }
                guard payload["type"] as? String == "item_completed",
                      let item = payload["item"] as? [String: Any], item["type"] as? String == "UserMessage" else { return }
                prompts += 1
                if firstPrompt == nil {
                    firstPrompt = text(of: item).map { String($0.prefix(300)) }
                }
            }
        }
        guard let id else { return nil }
        var chat = ChatSession(id: id, fileURL: file, projectDir: "codex", cwd: cwd, firstPrompt: firstPrompt,
                               promptCount: prompts, startedAt: started, modifiedAt: modified, sizeBytes: size)
        chat.provider = .codex
        if let title = titles[id] { chat.title = title; chat.isCustomTitle = true }
        return chat
    }

    static func text(of item: [String: Any]) -> String? {
        let parts = (item["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        let joined = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    /// The conversation for the preview: prompts, answers and the tools in between.
    static func read(_ url: URL, limit: Int = 500) -> (messages: [TranscriptMessage], truncated: Bool) {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return ([], false) }
        var messages: [TranscriptMessage] = []
        var tools: [String] = []
        let itemNeedle = Array(#""item_completed""#.utf8)
        func flush(_ date: Date?) {
            guard !tools.isEmpty else { return }
            messages.append(TranscriptMessage(id: messages.count, kind: .tools(tools), text: "", timestamp: date))
            tools = []
        }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            ChatIndexer.forEachLine(base: base, count: raw.count) { line, length in
                guard ChatIndexer.contains(line, length, itemNeedle),
                      let json = (try? JSONSerialization.jsonObject(with: Data(bytes: line, count: length))) as? [String: Any],
                      let item = (json["payload"] as? [String: Any])?["item"] as? [String: Any] else { return }
                let date = (json["timestamp"] as? String).flatMap { isoFormatter.date(from: $0) }
                switch item["type"] as? String {
                case "UserMessage":
                    if let text = text(of: item), !text.hasPrefix("<") {
                        flush(date)
                        messages.append(TranscriptMessage(id: messages.count, kind: .user, text: String(text.prefix(6000)), timestamp: date))
                    }
                case "AgentMessage":
                    if let text = text(of: item) {
                        flush(date)
                        messages.append(TranscriptMessage(id: messages.count, kind: .assistant, text: String(text.prefix(6000)), timestamp: date))
                    }
                case "CommandExecution":
                    let command = (item["command"] as? [String])?.last ?? ""
                    tools.append("Shell · \(command.replacingOccurrences(of: "\n", with: " ").prefix(90))")
                case "FileChange":
                    let paths = (item["changes"] as? [String: Any])?.keys.map { URL(fileURLWithPath: $0).lastPathComponent } ?? []
                    tools.append("Modifica · \(paths.joined(separator: ", ").prefix(90))")
                case "ImageView":
                    tools.append("Immagine")
                case "Extension":
                    tools.append(item["kind"] as? String ?? "Estensione")
                default:
                    break
                }
            }
        }
        flush(nil)
        let truncated = messages.count > limit
        return (truncated ? Array(messages.suffix(limit)) : messages, truncated)
    }

    /// Plan usage from the most recent session that recorded it (5 hours and week).
    static func planUsage() -> PlanUsage.Snapshot? {
        let files = sessionFiles().sorted {
            (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast
                > (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast
        }
        for file in files.prefix(5) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
                guard let json = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                      let limits = (json["payload"] as? [String: Any])?["rate_limits"] as? [String: Any] else { continue }
                func window(_ key: String) -> PlanUsage.Window? {
                    guard let entry = limits[key] as? [String: Any], let used = (entry["used_percent"] as? NSNumber)?.doubleValue else { return nil }
                    return PlanUsage.Window(percent: Int(used.rounded()),
                                            resets: (entry["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
                }
                var snapshot = PlanUsage.Snapshot(session: window("primary"), week: window("secondary"))
                snapshot.updated = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                return snapshot
            }
        }
        return nil
    }
}
