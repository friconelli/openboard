import XCTest
@testable import OpenBoard

final class RemoteServerTests: XCTestCase {
    func testOnlyTailscaleRange() {
        XCTAssertTrue(RemoteServer.isTailscale("100.101.246.93"))
        XCTAssertTrue(RemoteServer.isTailscale("100.64.0.1"))
        XCTAssertFalse(RemoteServer.isTailscale("100.128.0.1"))
        XCTAssertFalse(RemoteServer.isTailscale("192.168.1.10"))
        XCTAssertFalse(RemoteServer.isTailscale("127.0.0.1"))
    }

    func testSecretComparison() {
        XCTAssertTrue(RemoteServer.sameSecret("abc", "abc"))
        XCTAssertFalse(RemoteServer.sameSecret("abc", "abd"))
        XCTAssertFalse(RemoteServer.sameSecret("abc", "abcd"))
    }

    func testRequestParsing() throws {
        let raw = "POST /api/send?x=1 HTTP/1.1\r\nHost: a:1\r\nCookie: z=1; openboard=secret\r\nContent-Length: 2\r\n\r\n"
        XCTAssertNil(RemoteServer.Request.parse(Data(raw.utf8)), "body still missing")
        let request = try XCTUnwrap(RemoteServer.Request.parse(Data((raw + "{}").utf8)))
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/send")
        XCTAssertEqual(request.query["x"], "1")
        XCTAssertEqual(request.cookie, "secret")
        XCTAssertEqual(request.body, Data("{}".utf8))
    }

    func testPageNeverInjectsHTML() {
        XCTAssertFalse(RemoteAssets.script.contains("innerHTML"))
        XCTAssertFalse(RemoteAssets.html.contains("onclick="))
    }
}
