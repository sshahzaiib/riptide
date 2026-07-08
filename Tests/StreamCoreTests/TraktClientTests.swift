import XCTest
@testable import StreamCore

@MainActor
final class TraktClientTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.setHandler(nil)
        super.tearDown()
    }

    private func makeClient(tokens: TraktTokens? = nil) -> TraktClient {
        TraktClient(clientID: "cid", clientSecret: "csecret", tokens: tokens,
                    session: .mocked())
    }

    func testRequestDeviceCode() async throws {
        nonisolated(unsafe) var capturedPath: String?
        nonisolated(unsafe) var capturedMethod: String?
        nonisolated(unsafe) var capturedBody: Data?
        MockURLProtocol.setHandler { req in
            capturedPath = req.url?.path
            capturedMethod = req.httpMethod
            capturedBody = req.bodyData
            return .json(#"{"device_code":"dc1","user_code":"A1B2C3D4","verification_url":"https://trakt.tv/activate","expires_in":600,"interval":5}"#)
        }
        let code = try await makeClient().requestDeviceCode()
        XCTAssertEqual(code.userCode, "A1B2C3D4")
        XCTAssertEqual(code.deviceCode, "dc1")
        XCTAssertEqual(code.interval, 5)
        XCTAssertEqual(capturedPath, "/oauth/device/code")
        XCTAssertEqual(capturedMethod, "POST")
        let body = try JSONDecoder().decode([String: String].self,
                                            from: XCTUnwrap(capturedBody))
        XCTAssertEqual(body, ["client_id": "cid"])
    }

    func testPollDeviceTokenPendingReturnsNil() async throws {
        MockURLProtocol.setHandler { _ in .json("{}", status: 400) }
        let result = try await makeClient().pollDeviceToken(deviceCode: "dc1")
        XCTAssertNil(result)
    }

    func testPollDeviceTokenDeniedThrows() async {
        MockURLProtocol.setHandler { _ in .json("{}", status: 418) }
        do {
            _ = try await makeClient().pollDeviceToken(deviceCode: "dc1")
            XCTFail("expected throw")
        } catch { XCTAssertEqual(error as? TraktError, .denied) }
    }

    func testPollDeviceTokenSuccessStoresTokens() async throws {
        MockURLProtocol.setHandler { _ in
            .json(#"{"access_token":"at1","refresh_token":"rt1","created_at":100,"expires_in":7200}"#)
        }
        let client = makeClient()
        let tokens = try await client.pollDeviceToken(deviceCode: "dc1")
        XCTAssertEqual(tokens?.accessToken, "at1")
        XCTAssertEqual(client.tokens?.refreshToken, "rt1")
    }

    func testSendRefreshesOnceOn401AndNotifies() async throws {
        let start = TraktTokens(accessToken: "old", refreshToken: "rt-old",
                                createdAt: 0, expiresIn: 1)
        let client = makeClient(tokens: start)
        nonisolated(unsafe) var refreshed: TraktTokens?
        client.onTokensRefreshed = { refreshed = $0 }
        nonisolated(unsafe) var authHeaders: [String] = []
        MockURLProtocol.setHandler { req in
            if req.url!.path == "/oauth/token" {
                return .json(#"{"access_token":"new","refresh_token":"rt-new","created_at":200,"expires_in":7200}"#)
            }
            authHeaders.append(req.value(forHTTPHeaderField: "Authorization") ?? "none")
            return .json("[]", status: authHeaders.count == 1 ? 401 : 200)
        }
        _ = try await client.send(path: "/sync/playback")
        XCTAssertEqual(authHeaders, ["Bearer old", "Bearer new"])
        XCTAssertEqual(refreshed?.accessToken, "new")
    }
}
