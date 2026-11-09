import XCTest
@testable import AISwitchboard

/// Runs merge and split on copies of real transcripts listed in AISW_REAL_CHATS (colon-separated
/// paths). Skipped when the variable is not set. The originals are only read.
final class RealChatsTests: XCTestCase {
    func testMergeAndSplitRealCopies() throws {
        guard let list = ProcessInfo.processInfo.environment["AISW_REAL_CHATS"] else { throw XCTSkip("AISW_REAL_CHATS non impostata") }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("aisw-real-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        var chats: [ChatSession] = []
        for path in list.split(separator: ":").map(String.init) {
            let id = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            let copy = dir.appendingPathComponent("\(id).jsonl")
            try fm.copyItem(atPath: path, toPath: copy.path)
            chats.append(ChatSession(id: id, fileURL: copy, projectDir: dir.lastPathComponent, modifiedAt: Date(), sizeBytes: 0))
        }

        let merged = try MergeEngine.merge(chats, title: "prova", targetFolder: dir, configDirs: [])
        print("MERGE ok: \(merged.messageCount) messaggi in catena")

        for chat in chats {
            let source = try SplitEngine.analyze(chat)
            let half = source.turns.count / 2
            let folder = dir.appendingPathComponent("split").path
            let results = try SplitEngine.split(source, topics: [
                .init(title: "Prima", description: nil, folder: folder, turns: Array(0..<half), summary: "riassunto"),
                .init(title: "Seconda", description: nil, folder: folder, turns: Array(half..<source.turns.count), summary: "riassunto"),
            ], configDirs: [])
            defer { if let p = results.first?.projectDir { try? fm.removeItem(at: ClaudePaths.projects.appendingPathComponent(p)) } }
            let tokens = SplitEngine.tokens(of: Array(0..<source.turns.count), in: source)
            let fit = SplitEngine.fit(Array(half..<source.turns.count), in: source)
            print("SPLIT ok \(chat.id.prefix(8)): \(source.turns.count) turni, ~\(tokens / 1000)k token totali, seconda metà: \(fit.kept.count) in chat + \(fit.archived.count) solo nel riassunto; messaggi \(results.map(\.messageCount))")

            let slim = try SlimEngine.analyze(chat)
            let plan = SlimEngine.plan(slim, enabled: Set(SlimEngine.Category.allCases.filter(\.defaultOn)))
            print("SLIM plan \(chat.id.prefix(8)): -\(plan.bytesSaved / 1024) KB, -\(plan.tokensSaved / 1000)k token stimati")
        }
    }
}
