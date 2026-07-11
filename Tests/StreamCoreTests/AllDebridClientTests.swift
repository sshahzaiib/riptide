import XCTest
@testable import StreamCore

final class AllDebridClientTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.setHandler(nil)
        super.tearDown()
    }

    private func client() -> AllDebridClient {
        AllDebridClient(token: "adkey", session: .mocked(),
                        config: .init(maxRetries: 2, retryBaseDelay: 0.001,
                                      pollInterval: 0.001, pollTimeout: 1),
                        sleep: { _ in })
    }

    func testMagnetUploadRequestShape() async throws {
        nonisolated(unsafe) var captured: (path: String?, auth: String?, body: String?)
        MockURLProtocol.setHandler { req in
            captured = (req.url?.path,
                        req.value(forHTTPHeaderField: "Authorization"),
                        req.bodyData.flatMap { String(data: $0, encoding: .utf8) })
            return .json(#"{"status":"success","data":{"magnets":[{"id":123,"ready":false,"hash":"cafebabe","name":"Pack","size":900}]}}"#)
        }
        let up = try await client().magnetUpload("magnet:?xt=urn:btih:cafebabe")
        XCTAssertEqual(captured.path, "/v4/magnet/upload")
        XCTAssertEqual(captured.auth, "Bearer adkey")
        XCTAssertEqual(captured.body, "magnets%5B%5D=magnet%3A%3Fxt%3Durn%3Abtih%3Acafebabe")
        XCTAssertEqual(up.id, 123)
        XCTAssertEqual(up.ready, false)
        XCTAssertEqual(up.hash, "cafebabe")
    }

    func testCachedUploadReportsReady() async throws {
        MockURLProtocol.setHandler { _ in
            .json(#"{"status":"success","data":{"magnets":[{"id":9,"ready":true}]}}"#)
        }
        let up = try await client().magnetUpload("magnet:?xt=urn:btih:beef")
        XCTAssertEqual(up.ready, true)
    }

    func testAuthErrorMapsToAuthFailed() async {
        MockURLProtocol.setHandler { _ in
            .json(#"{"status":"error","error":{"code":"AUTH_BAD_APIKEY","message":"The auth apikey is invalid"}}"#)
        }
        do { _ = try await client().magnetUpload("magnet:?xt=urn:btih:x"); XCTFail("expected throw") }
        catch AllDebridError.authFailed {} catch { XCTFail("wrong error \(error)") }
    }

    /// AD reports per-magnet failures INSIDE the magnets array, with a
    /// success top-level envelope.
    func testPerMagnetErrorMapsToMagnetRejected() async {
        MockURLProtocol.setHandler { _ in
            .json(#"{"status":"success","data":{"magnets":[{"magnet":"bad","error":{"code":"MAGNET_INVALID_URI","message":"Invalid magnet"}}]}}"#)
        }
        do { _ = try await client().magnetUpload("bad"); XCTFail("expected throw") }
        catch AllDebridError.magnetRejected(let code) { XCTAssertEqual(code, "MAGNET_INVALID_URI") }
        catch { XCTFail("wrong error \(error)") }
    }

    func testRateLimitRetriesThenSucceeds() async throws {
        nonisolated(unsafe) var calls = 0
        MockURLProtocol.setHandler { _ in
            calls += 1
            if calls == 1 { return .init(status: 429) }
            return .json(#"{"status":"success","data":{"magnets":[{"id":1,"ready":true}]}}"#)
        }
        _ = try await client().magnetUpload("magnet:?xt=urn:btih:x")
        XCTAssertEqual(calls, 2)
    }

    func testRateLimitExhaustsRetries() async {
        MockURLProtocol.setHandler { _ in .init(status: 429) }
        do { _ = try await client().magnetUpload("magnet:?xt=urn:btih:x"); XCTFail("expected throw") }
        catch AllDebridError.rateLimited {} catch { XCTFail("wrong error \(error)") }
    }
}
