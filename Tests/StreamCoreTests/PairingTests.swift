import XCTest
@testable import StreamCore

final class PairingTests: XCTestCase {
    func testPayloadRoundTripsThroughJSON() throws {
        var p = PairingPayload(); p.rdToken = "abc"; p.addonURLs = ["https://x/manifest.json"]; p.clear = ["adToken"]
        let data = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(PairingPayload.self, from: data), p)
    }
    func testFormDecodingTrimsAddonURLs() {
        let p = PairingPayload.fromForm("rdToken=abc&addonURLs=%20https%3A%2F%2Fa%2Fmanifest.json%20%0A%0Ahttps%3A%2F%2Fb%0A&clear_adToken=on")
        XCTAssertEqual(p.rdToken, "abc")
        XCTAssertEqual(p.addonURLs, ["https://a/manifest.json", "https://b"])
        XCTAssertEqual(p.clear, ["adToken"])
        XCTAssertNil(p.tmdbToken)
    }
    func testParseWaitsForFullBody() {
        let head = Data("POST /abcd1234 HTTP/1.1\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 11\r\n\r\nrdToken".utf8)
        XCTAssertNil(PairingHTTP.parse(head))
        let full = head + Data("=abc".utf8)
        let req = PairingHTTP.parse(full)
        XCTAssertEqual(req?.method, "POST"); XCTAssertEqual(req?.path, "/abcd1234"); XCTAssertEqual(req?.body, "rdToken=abc")
    }
    func testRequestOnWrongPathIsRejected() {
        let req = PairingHTTP.parse(Data("GET /other HTTP/1.1\r\n\r\n".utf8))
        XCTAssertEqual(req?.path, "/other")
        let resp = String(decoding: PairingHTTP.response(status: 404, html: "<p>no</p>"), as: UTF8.self)
        XCTAssertTrue(resp.hasPrefix("HTTP/1.1 404 Not Found\r\n"))
        XCTAssertTrue(resp.contains("Content-Length: 9\r\n"))
    }
    func testPageShowsSetFieldsWithClearAndNoScript() {
        let html = PairingPage.html(fields: [
            .init(name: "rdToken", label: "Real-Debrid API key", isSet: true, result: nil),
            .init(name: "tmdbToken", label: "TMDB read token", isSet: false, result: "Rejected by TMDB"),
        ], token: "abcd1234")
        XCTAssertTrue(html.contains("action=\"/abcd1234\""))
        XCTAssertTrue(html.contains("name=\"clear_rdToken\""))
        XCTAssertFalse(html.contains("name=\"clear_tmdbToken\""))
        XCTAssertTrue(html.contains("Rejected by TMDB"))
        XCTAssertFalse(html.lowercased().contains("<script"))
    }
    func testParseRejectsMalformedContentLength() {
        XCTAssertNil(PairingHTTP.parse(Data("POST /x HTTP/1.1\r\nContent-Length: -5\r\n\r\nabc".utf8)))
        XCTAssertNil(PairingHTTP.parse(Data("POST /x HTTP/1.1\r\nContent-Length: abc\r\n\r\nabc".utf8)))
        XCTAssertNil(PairingHTTP.parse(Data([0xFF, 0xFE])))
    }
}
