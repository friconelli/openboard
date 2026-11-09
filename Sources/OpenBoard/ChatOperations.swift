import Foundation

enum ChatOperationError: LocalizedError {
    case active(String)
    case io(String)

    var errorDescription: String? {
        switch self {
        case .active(let title): return "“\(title)” è in uso in una sessione aperta: chiudila prima."
        case .io(let message): return message
        }
    }
}

enum ChatOperations {
    // MARK: - Rename

    /// Same records `/rename` writes: Claude Code picks the last one.
    static func rename(_ session: ChatSession, to title: String) throws {
        // Written by hand to keep Claude Code's own field order.
        let lines = [
            #"{"type":"custom-title","customTitle":\#(jsonString(title)),"sessionId":\#(jsonString(session.id))}"#,
            #"{"type":"agent-name","agentName":\#(jsonString(title)),"sessionId":\#(jsonString(session.id))}"#,
        ]
        try appendLines(lines, to: session.fileURL)
    }

    // MARK: - Delete

    /// Moves the transcript and its side folder (tool results, subagents) to the Trash.
    /// Returns where each item went, so the move can be undone.
    @discardableResult
    static func trash(_ session: ChatSession) throws -> [UndoAction.Restore] {
        var moved = [try trashItem(session.fileURL)]
        let sideDir = session.fileURL.deletingPathExtension()
        if FileManager.default.fileExists(atPath: sideDir.path) {
            moved.append(try trashItem(sideDir))
        }
        return moved
    }

    static func trashItem(_ url: URL) throws -> UndoAction.Restore {
        var trashed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
        return UndoAction.Restore(trashed: (trashed as URL?) ?? url, original: url)
    }

    // MARK: - Helpers

    /// A JSON string literal (with quotes) for `value`.
    static func jsonString(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    static func appendLines(_ lines: [String], to url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        var payload = Data()
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            if handle.readData(ofLength: 1) != Data([0x0A]) { payload.append(0x0A) }
            try handle.seekToEnd()
        }
        for line in lines {
            payload.append(Data(line.utf8))
            payload.append(0x0A)
        }
        try handle.write(contentsOf: payload)
    }

    static func append(_ records: [[String: Any]], to url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        var payload = Data()
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            if handle.readData(ofLength: 1) != Data([0x0A]) { payload.append(0x0A) }
            try handle.seekToEnd()
        }
        for record in records {
            payload.append(try JSONSerialization.data(withJSONObject: record, options: [.withoutEscapingSlashes]))
            payload.append(0x0A)
        }
        try handle.write(contentsOf: payload)
    }
}

/// How to take back the last operation that sent files to the Trash: put them back where they
/// were, after sending to the Trash what the operation created (a merged chat, the slimmed copy).
struct UndoAction: Identifiable {
    struct Restore: Sendable {
        let trashed: URL
        let original: URL
    }

    let id = UUID()
    let message: String
    var restores: [Restore] = []
    var trashFirst: [URL] = []

    func perform() throws {
        let fm = FileManager.default
        for url in trashFirst where fm.fileExists(atPath: url.path) {
            try fm.trashItem(at: url, resultingItemURL: nil)
        }
        for item in restores {
            guard !fm.fileExists(atPath: item.original.path) else {
                throw ChatOperationError.io("\(item.original.lastPathComponent) esiste già: lo lascio nel Cestino")
            }
            try fm.createDirectory(at: item.original.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: item.trashed, to: item.original)
        }
    }
}
