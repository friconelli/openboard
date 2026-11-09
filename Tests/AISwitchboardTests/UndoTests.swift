import XCTest
@testable import AISwitchboard

final class UndoTests: XCTestCase {
    func testUndoPutsFilesBackAndRefusesToOverwrite() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("aisw-undo-\(UUID().uuidString)")
        let bin = dir.appendingPathComponent("bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let trashed = bin.appendingPathComponent("a.jsonl")
        try Data("orig".utf8).write(to: trashed)
        let original = dir.appendingPathComponent("project/a.jsonl")
        try UndoAction(message: "x", restores: [.init(trashed: trashed, original: original)]).perform()
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "orig")

        // Something already back in place is never overwritten.
        try Data("again".utf8).write(to: trashed)
        XCTAssertThrowsError(try UndoAction(message: "x", restores: [.init(trashed: trashed, original: original)]).perform())
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "orig")
    }
}
