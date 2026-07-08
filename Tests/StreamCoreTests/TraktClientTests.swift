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

    func testConcurrent401sShareOneRefresh() async throws {
        let start = TraktTokens(accessToken: "old", refreshToken: "rt-old",
                                createdAt: 0, expiresIn: 1)
        let client = makeClient(tokens: start)
        nonisolated(unsafe) var refreshCount = 0
        MockURLProtocol.setHandler { req in
            if req.url!.path == "/oauth/token" {
                refreshCount += 1
                return .json(#"{"access_token":"new","refresh_token":"rt-new","created_at":200,"expires_in":7200}"#)
            }
            // Old token 401s, refreshed token succeeds.
            let auth = req.value(forHTTPHeaderField: "Authorization")
            return .json("[]", status: auth == "Bearer old" ? 401 : 200)
        }
        async let a = client.send(path: "/sync/playback")
        async let b = client.send(path: "/sync/watched/movies")
        _ = try await (a, b)
        XCTAssertEqual(refreshCount, 1)
    }

    func testServerErrorAfterRefreshIsNotUnauthorized() async {
        let start = TraktTokens(accessToken: "old", refreshToken: "rt-old",
                                createdAt: 0, expiresIn: 1)
        let client = makeClient(tokens: start)
        MockURLProtocol.setHandler { req in
            if req.url!.path == "/oauth/token" {
                return .json(#"{"access_token":"new","refresh_token":"rt-new","created_at":200,"expires_in":7200}"#)
            }
            let auth = req.value(forHTTPHeaderField: "Authorization")
            return .json("{}", status: auth == "Bearer old" ? 401 : 502)
        }
        do {
            _ = try await client.send(path: "/sync/playback")
            XCTFail("expected throw")
        } catch { XCTAssertEqual(error as? TraktError, .http(502)) }
    }

    // MARK: Task 2 — scrobble / pulls / ratings

    private func tok() -> TraktTokens {
        TraktTokens(accessToken: "at", refreshToken: "rt", createdAt: 0, expiresIn: 9999)
    }

    func testScrobbleMoviePayload() async throws {
        nonisolated(unsafe) var capturedPath: String?
        nonisolated(unsafe) var capturedHeaders: [String: String] = [:]
        nonisolated(unsafe) var capturedBody: Data?
        MockURLProtocol.setHandler { req in
            capturedPath = req.url?.path
            for key in ["trakt-api-key", "trakt-api-version", "Authorization"] {
                capturedHeaders[key] = req.value(forHTTPHeaderField: key)
            }
            capturedBody = req.bodyData
            return .json("{}", status: 201)
        }
        try await makeClient(tokens: tok()).scrobble(.start, media: .movie(tmdbID: 603),
                                                     progress: 12.5)
        XCTAssertEqual(capturedPath, "/scrobble/start")
        XCTAssertEqual(capturedHeaders["trakt-api-key"], "cid")
        XCTAssertEqual(capturedHeaders["trakt-api-version"], "2")
        XCTAssertEqual(capturedHeaders["Authorization"], "Bearer at")
        let json = try JSONSerialization.jsonObject(
            with: XCTUnwrap(capturedBody)) as! [String: Any]
        XCTAssertEqual((json["movie"] as! [String: Any])["ids"] as! [String: Int], ["tmdb": 603])
        XCTAssertEqual(json["progress"] as! Double, 12.5)
        XCTAssertNil(json["episode"])
    }

    func testScrobbleEpisodePayload() async throws {
        nonisolated(unsafe) var capturedBody: Data?
        MockURLProtocol.setHandler { req in
            capturedBody = req.bodyData
            return .json("{}", status: 201)
        }
        try await makeClient(tokens: tok()).scrobble(
            .stop, media: .episode(showTMDBID: 1399, season: 1, episode: 5), progress: 97)
        let json = try JSONSerialization.jsonObject(
            with: XCTUnwrap(capturedBody)) as! [String: Any]
        XCTAssertEqual((json["show"] as! [String: Any])["ids"] as! [String: Int], ["tmdb": 1399])
        XCTAssertEqual(json["episode"] as! [String: Int], ["season": 1, "number": 5])
    }

    func testPlaybackDecodes() async throws {
        MockURLProtocol.setHandler { _ in .json(#"""
        [{"progress":25.5,"paused_at":"2026-07-01T09:10:11.000Z","type":"episode",
          "episode":{"season":1,"number":5},"show":{"ids":{"tmdb":1399}}},
         {"progress":64.0,"paused_at":"2026-07-02T20:00:00.000Z","type":"movie",
          "movie":{"ids":{"tmdb":603}}}]
        """#) }
        let entries = try await makeClient(tokens: tok()).playback()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].show?.ids.tmdb, 1399)
        XCTAssertEqual(entries[0].episode?.number, 5)
        XCTAssertEqual(entries[1].movie?.ids.tmdb, 603)
        XCTAssertNotNil(entries[0].pausedAt)
    }

    func testWatchedShowsDecodes() async throws {
        MockURLProtocol.setHandler { _ in .json(#"""
        [{"show":{"ids":{"tmdb":1399}},
          "seasons":[{"number":1,"episodes":[
            {"number":1,"last_watched_at":"2026-06-30T21:00:00.000Z"},
            {"number":2,"last_watched_at":"2026-07-01T21:00:00.000Z"}]}]}]
        """#) }
        let shows = try await makeClient(tokens: tok()).watchedShows()
        XCTAssertEqual(shows[0].show.ids.tmdb, 1399)
        XCTAssertEqual(shows[0].seasons[0].episodes.count, 2)
    }

    func testWatchedShowsMissingSeasonsDecodes() async throws {
        // Regression: a real account returned an entry with no `seasons` key,
        // which used to fail the whole pull with keyNotFound.
        MockURLProtocol.setHandler { _ in .json(#"""
        [{"show":{"ids":{"tmdb":777}}},
         {"show":{"ids":{"tmdb":1399}},
          "seasons":[{"number":1},
                     {"number":2,"episodes":[
                       {"number":1,"last_watched_at":"2026-07-01T21:00:00.000Z"}]}]}]
        """#) }
        let shows = try await makeClient(tokens: tok()).watchedShows()
        XCTAssertEqual(shows.count, 2)
        XCTAssertEqual(shows[0].seasons, [])
        XCTAssertEqual(shows[1].seasons[0].episodes, [])
        XCTAssertEqual(shows[1].seasons[1].episodes.count, 1)
    }

    func testRateShowPayload() async throws {
        nonisolated(unsafe) var capturedPath: String?
        nonisolated(unsafe) var capturedBody: Data?
        MockURLProtocol.setHandler { req in
            capturedPath = req.url?.path
            capturedBody = req.bodyData
            return .json("{}", status: 201)
        }
        try await makeClient(tokens: tok()).rate(media: .show(tmdbID: 1399), rating: 9)
        XCTAssertEqual(capturedPath, "/sync/ratings")
        let json = try JSONSerialization.jsonObject(
            with: XCTUnwrap(capturedBody)) as! [String: Any]
        let shows = json["shows"] as! [[String: Any]]
        XCTAssertEqual(shows[0]["rating"] as! Int, 9)
        XCTAssertEqual(shows[0]["ids"] as! [String: Int], ["tmdb": 1399])
        XCTAssertNil(json["movies"])
    }
}
