import XCTest
@testable import OpenBoard

/// Manual check on a real transcript copy: `SLIM_FILE=/path/copy.jsonl swift test --filter SlimLiveCheck`.
final class SlimLiveCheck: XCTestCase {
    func testSlimCopy() throws {
        guard let path = ProcessInfo.processInfo.environment["SLIM_FILE"] else { throw XCTSkip("SLIM_FILE not set") }
        let url = URL(fileURLWithPath: path)
        let size = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        let chat = ChatSession(id: url.deletingPathExtension().lastPathComponent, fileURL: url, projectDir: "x", modifiedAt: Date(), sizeBytes: size)
        let source = try SlimEngine.analyze(chat)
        let only = ProcessInfo.processInfo.environment["SLIM_CATS"].map { Set($0.split(separator: ",").compactMap { SlimEngine.Category(rawValue: String($0)) }) }
        let plan = SlimEngine.plan(source, enabled: only ?? Set(SlimEngine.Category.allCases.filter(\.defaultOn)))
        for (category, saving) in plan.savings { print("SLIM", category.rawValue, saving.bytes, saving.tokens, saving.items) }
        print("SLIM context", source.contextTokens, "saved", plan.tokensSaved, "bytes", plan.bytesSaved)
        let outcome = try SlimEngine.apply(source, plan: plan)
        print("SLIM size", outcome.before, "->", outcome.after)
    }
}
