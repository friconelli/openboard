import XCTest
@testable import OpenBoard

final class GitAndFilesTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("aisw-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testGitStatusAndDiff() throws {
        let path = dir.path
        XCTAssertNotNil(Git.run(["init", "-q", "-b", "main"], in: path))
        _ = Git.run(["config", "user.email", "t@example.com"], in: path)
        _ = Git.run(["config", "user.name", "Test"], in: path)
        try "uno\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = Git.run(["add", "-A"], in: path)
        XCTAssertNotNil(Git.run(["commit", "-q", "-m", "primo"], in: path))
        try "uno\ndue\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "nuovo\n".write(to: dir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let status = try XCTUnwrap(Git.status(of: path))
        XCTAssertEqual(status.branch, "main")
        XCTAssertEqual(Set(status.changes.map(\.path)), ["a.txt", "b.txt"])
        XCTAssertEqual(status.log.first?.subject, "primo")
        let modified = try XCTUnwrap(status.changes.first { $0.path == "a.txt" })
        XCTAssertTrue(Git.diff(modified, root: status.root).contains("+due"))
        XCTAssertTrue(ChangedFiles.gitDiff(for: dir.appendingPathComponent("b.txt").path)?.contains("+nuovo") == true)
        XCTAssertNil(Git.status(of: FileManager.default.temporaryDirectory.path))
    }

    func testChangedFilesFromTranscript() throws {
        let url = dir.appendingPathComponent("chat.jsonl")
        try MergeEngine.write([
            ["type": "assistant", "uuid": "1", "timestamp": "2026-11-09T10:00:00.000Z", "message": ["role": "assistant", "content": [
                ["type": "tool_use", "id": "t1", "name": "Write", "input": ["file_path": "/x/a.txt", "content": "ciao"]],
                ["type": "tool_use", "id": "t2", "name": "Edit", "input": ["file_path": "/x/a.txt", "old_string": "ciao", "new_string": "salve"]],
                ["type": "tool_use", "id": "t3", "name": "Read", "input": ["file_path": "/x/b.txt"]],
            ]]],
        ], to: url)
        let files = ChangedFiles.scan(url)
        XCTAssertEqual(files.map(\.path), ["/x/a.txt"])
        XCTAssertEqual(files.first?.edits.count, 2)
        XCTAssertTrue(ChangedFiles.editsAsDiff(files[0]).contains("-ciao\n+salve"))
    }
}
