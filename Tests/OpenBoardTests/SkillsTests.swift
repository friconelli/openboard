import XCTest
@testable import OpenBoard

final class SkillsTests: XCTestCase {
    func testRoundTripAndFoldedDescription() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("SKILL.md")
        try SkillLibrary.document(name: "controllo-seo", description: "Usa: quando \"pubblichi\" una pagina", body: "1. Fai X").write(to: file, atomically: true, encoding: .utf8)
        let parsed = try XCTUnwrap(SkillLibrary.parse(file))
        XCTAssertEqual(parsed.name, "controllo-seo")
        XCTAssertEqual(parsed.description, "Usa: quando \"pubblichi\" una pagina")
        XCTAssertEqual(parsed.body, "1. Fai X")

        try "---\nname: x\ndescription: >\n  riga uno\n  riga due\nother: 1\n---\nCorpo".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(SkillLibrary.parse(file)?.description, "riga uno riga due")
    }

    func testSlug() {
        XCTAssertEqual(SkillLibrary.slug("Controllo SEO città!"), "controllo-seo-citta")
    }

    func testImageSizeFromPNGHeader() {
        // 1x1 PNG
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
        XCTAssertEqual(SlimEngine.imageSize(base64: png)?.width, 1)
    }
}
