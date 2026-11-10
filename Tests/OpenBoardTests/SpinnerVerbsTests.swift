import XCTest
@testable import OpenBoard

final class SpinnerVerbsTests: XCTestCase {
    func testReadsTheListFromTheInstalledClaude() throws {
        guard let path = ClaudeAssistant.binaryPath else { throw XCTSkip("claude non installato") }
        let list = try XCTUnwrap(SpinnerVerbs.extract(from: URL(fileURLWithPath: path).resolvingSymlinksInPath()))
        XCTAssertTrue(list.contains("Clauding"))
        XCTAssertGreaterThan(list.count, 100)
        XCTAssertFalse(list.contains { $0.contains("\\x") })
        print("verbi:", list.count, list.filter { $0.unicodeScalars.contains { !$0.isASCII } })
    }
}

final class ModelNamesTests: XCTestCase {
    func testPrettyNames() {
        XCTAssertEqual(ModelNames.pretty("claude-opus-5-5"), "Opus 5.5")
        XCTAssertEqual(ModelNames.pretty("claude-sonnet-4-5-20250929"), "Sonnet 4.5")
        XCTAssertEqual(ModelNames.pretty("claude-fable-5-1[1m]"), "Fable 5.1")
        XCTAssertEqual(ModelNames.pretty("opus"), "Opus")
    }
}
