import XCTest
@testable import OpenBoard

/// When Claude makes several tool calls in one answer, Claude Code writes every call as its own
/// line and the result of each call but the last as a sibling branch, off the main chain.
/// Merge, split and slim must keep those results.
final class ParallelToolResultsTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("aisw-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// P1 → A(call 1) → B(call 2) → R2 → C → P2 → D, plus R1 (result of call 1) hanging off A.
    private func makeChat(prefix: String) throws -> ChatSession {
        let id = UUID().uuidString.lowercased()
        let u = { (name: String) in "\(prefix)-\(name)-0000-0000-000000000000" }
        func line(_ uuid: String, _ parent: String?, _ type: String, _ content: Any, message: String? = nil) -> [String: Any] {
            var msg: [String: Any] = ["role": type, "content": content]
            if let message { msg["id"] = message }
            return ["uuid": u(uuid), "parentUuid": parent.map { u($0) as Any } ?? NSNull(), "type": type,
                    "isSidechain": false, "sessionId": id, "cwd": "/tmp", "timestamp": "2026-11-09T10:00:00.000Z",
                    "message": msg]
        }
        let records: [[String: Any]] = [
            line("p1", nil, "user", "leggi due file"),
            line("a", "p1", "assistant", [["type": "tool_use", "id": "\(prefix)tu1", "name": "Read", "input": ["file_path": "/a"]]], message: "m1"),
            line("b", "a", "assistant", [["type": "tool_use", "id": "\(prefix)tu2", "name": "Read", "input": ["file_path": "/b"]]], message: "m1"),
            line("r1", "a", "user", [["type": "tool_result", "tool_use_id": "\(prefix)tu1", "content": "contenuto A"]]),
            line("r2", "b", "user", [["type": "tool_result", "tool_use_id": "\(prefix)tu2", "content": "contenuto B"]]),
            line("c", "r2", "assistant", [["type": "text", "text": "fatto"]], message: "m2"),
            line("p2", "c", "user", "altro argomento"),
            line("d", "p2", "assistant", [["type": "text", "text": "ok"]], message: "m3"),
        ]
        let url = dir.appendingPathComponent("\(id).jsonl")
        try MergeEngine.write(records, to: url)
        return ChatSession(id: id, fileURL: url, projectDir: dir.lastPathComponent, modifiedAt: Date(), sizeBytes: 0)
    }

    private func toolResults(in url: URL) throws -> Set<String> {
        var ids: Set<String> = []
        for line in try Data(contentsOf: url).split(separator: 0x0A) {
            let json = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] ?? [:]
            let blocks = (json["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for block in blocks where block["type"] as? String == "tool_result" {
                ids.insert(block["tool_use_id"] as? String ?? "")
            }
        }
        return ids
    }

    func testParallelResultsAreDetected() throws {
        let chat = try makeChat(prefix: "aaaaaaaa")
        let records = try Data(contentsOf: chat.fileURL).split(separator: 0x0A)
            .map { try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any] }
        let chain: Set<String> = Set(["p1", "a", "b", "r2", "c", "p2", "d"].map { "aaaaaaaa-\($0)-0000-0000-000000000000" })
        XCTAssertEqual(MergeEngine.parallelResults(records, on: chain), ["aaaaaaaa-r1-0000-0000-000000000000"])
    }

    func testMergeKeepsParallelResults() throws {
        let first = try makeChat(prefix: "aaaaaaaa")
        let second = try makeChat(prefix: "bbbbbbbb")
        let result = try MergeEngine.merge([first, second], title: "Unita", targetFolder: dir, configDirs: [])
        XCTAssertEqual(try toolResults(in: result.fileURL), ["aaaaaaaatu1", "aaaaaaaatu2", "bbbbbbbbtu1", "bbbbbbbbtu2"])
        XCTAssertEqual(result.messageCount, 14)
    }

    func testSlimKeepsParallelResults() throws {
        let chat = try makeChat(prefix: "aaaaaaaa")
        let source = try SlimEngine.analyze(chat)
        let plan = SlimEngine.plan(source, enabled: Set(SlimEngine.Category.allCases))
        XCTAssertEqual(plan.savings[.technical]?.items ?? 0, 0, "the sibling result was taken for an undone branch")
    }

    func testSplitKeepsParallelResultsWithTheirTurn() throws {
        let chat = try makeChat(prefix: "aaaaaaaa")
        let source = try SplitEngine.analyze(chat)
        XCTAssertEqual(source.turns.count, 2)
        let folder = dir.appendingPathComponent("split-target").path
        let results = try SplitEngine.split(source, topics: [
            .init(title: "Lettura", description: nil, folder: folder, turns: [0], summary: nil),
            .init(title: "Altro", description: nil, folder: folder, turns: [1], summary: nil),
        ], configDirs: [])
        defer {
            if let projectDir = results.first?.projectDir {
                try? FileManager.default.removeItem(at: ClaudePaths.projects.appendingPathComponent(projectDir))
            }
        }
        XCTAssertEqual(try toolResults(in: results[0].fileURL), ["aaaaaaaatu1", "aaaaaaaatu2"])
        XCTAssertEqual(results[1].messageCount, 2)
    }

    func testForkAnchorFindsTurnByPrompt() throws {
        let chat = try makeChat(prefix: "aaaaaaaa")
        let source = try SplitEngine.analyze(chat)
        XCTAssertEqual(SplitEngine.turn(matching: "altro argomento", occurrence: 0, in: source), 1)
        XCTAssertEqual(SplitEngine.turn(matching: "  leggi   due file ", occurrence: 0, in: source), 0, "compared as cleaned text")
        XCTAssertNil(SplitEngine.turn(matching: "mai detto", occurrence: 0, in: source))
    }

    func testSplitBudgetKeepsLatestTurns() throws {
        let chat = try makeChat(prefix: "aaaaaaaa")
        let source = try SplitEngine.analyze(chat)
        let fitted = SplitEngine.fit([1, 0], in: source)
        XCTAssertEqual(fitted.kept, [0, 1])
        XCTAssertEqual(fitted.archived, [])
    }
}

final class ResumeFolderTests: XCTestCase {
    func testResumeFolderMatchesTranscriptFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aisw-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("\(UUID().uuidString.lowercased()).jsonl")
        // A merged chat: the first message ran in another project, the rest in ~/projects.
        try MergeEngine.write([
            ["type": "user", "uuid": "1", "cwd": "/Users/x/projects/gone", "message": ["role": "user", "content": "a"]],
            ["type": "user", "uuid": "2", "cwd": "/Users/x/projects", "message": ["role": "user", "content": "b"]],
        ], to: url)
        let chat = ChatIndexer.index(file: url, projectDir: "-Users-x-projects", size: 0, modified: Date())
        XCTAssertEqual(chat?.cwd, "/Users/x/projects")
    }

    func testResumeFolderFallsBackToAncestor() {
        XCTAssertEqual(ChatIndexer.ancestor(of: "/Users/x/projects/site/src", encodedAs: "-Users-x-projects"), "/Users/x/projects")
        XCTAssertNil(ChatIndexer.ancestor(of: "/tmp/a", encodedAs: "-Users-x-projects"))
    }
}
