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

    func testWatchedShowsDecodesShallowEntries() async throws {
        // Live API shape: no `seasons` key at all (docs are stale) — episode
        // data comes from the separate progress endpoint.
        MockURLProtocol.setHandler { _ in .json(#"""
        [{"plays":5,"last_watched_at":"2026-07-08T08:09:00.000Z",
          "show":{"ids":{"tmdb":1399,"trakt":1390}}}]
        """#) }
        let shows = try await makeClient(tokens: tok()).watchedShows()
        XCTAssertEqual(shows[0].show.ids.tmdb, 1399)
        XCTAssertEqual(shows[0].show.ids.trakt, 1390)
    }

    func testShowProgressDecodesAndUsesTraktID() async throws {
        nonisolated(unsafe) var capturedPath: String?
        MockURLProtocol.setHandler { req in
            capturedPath = req.url?.path
            return .json(#"""
            {"aired":73,"completed":2,"seasons":[
              {"number":1,"aired":10,"episodes":[
                {"number":1,"completed":true,"last_watched_at":"2026-07-01T21:00:00.000Z"},
                {"number":2,"completed":false,"last_watched_at":null}]}]}
            """#)
        }
        let progress = try await makeClient(tokens: tok()).showProgress(traktID: 1390)
        XCTAssertEqual(capturedPath, "/shows/1390/progress/watched")
        XCTAssertEqual(progress.seasons[0].episodes[0].completed, true)
        XCTAssertNotNil(progress.seasons[0].episodes[0].lastWatchedAt)
        XCTAssertEqual(progress.seasons[0].episodes[1].completed, false)
        XCTAssertNil(progress.seasons[0].episodes[1].lastWatchedAt)
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

    func testAddToHistoryBatchesEpisodesByShowAndSeason() async throws {
        nonisolated(unsafe) var capturedPath: String?
        nonisolated(unsafe) var capturedBody: Data?
        MockURLProtocol.setHandler { req in
            capturedPath = req.url?.path
            capturedBody = req.bodyData
            return .json(#"{"added":{"episodes":3}}"#, status: 201)
        }
        try await makeClient(tokens: tok()).addToHistory([
            .episode(showTMDBID: 1396, season: 1, episode: 2),
            .episode(showTMDBID: 1396, season: 1, episode: 1),
            .episode(showTMDBID: 1396, season: 2, episode: 5),
        ])
        XCTAssertEqual(capturedPath, "/sync/history")

        let json = try JSONSerialization.jsonObject(
            with: XCTUnwrap(capturedBody)) as! [String: Any]
        let shows = try XCTUnwrap(json["shows"] as? [[String: Any]])
        XCTAssertEqual(shows.count, 1)
        XCTAssertEqual((shows[0]["ids"] as? [String: Int])?["tmdb"], 1396)
        let seasons = try XCTUnwrap(shows[0]["seasons"] as? [[String: Any]])
        XCTAssertEqual(seasons.map { $0["number"] as? Int }, [1, 2])
        let s1Episodes = try XCTUnwrap(seasons[0]["episodes"] as? [[String: Int]])
        XCTAssertEqual(s1Episodes.map { $0["number"] }, [1, 2])   // sorted
        XCTAssertNil(json["movies"])
    }

    func testRemoveFromHistoryMovieRoute() async throws {
        nonisolated(unsafe) var capturedPath: String?
        nonisolated(unsafe) var capturedBody: Data?
        MockURLProtocol.setHandler { req in
            capturedPath = req.url?.path
            capturedBody = req.bodyData
            return .json(#"{"deleted":{"movies":1}}"#)
        }
        try await makeClient(tokens: tok())
            .removeFromHistory([.movie(tmdbID: 603)])
        XCTAssertEqual(capturedPath, "/sync/history/remove")
        let json = try JSONSerialization.jsonObject(
            with: XCTUnwrap(capturedBody)) as! [String: Any]
        let movies = try XCTUnwrap(json["movies"] as? [[String: [String: Int]]])
        XCTAssertEqual(movies, [["ids": ["tmdb": 603]]])
        XCTAssertNil(json["shows"])
    }

    func testHistoryBodyMixedShowAndEpisodeOrders() {
        // (a) [.show(1396), .episode(1396, s1e1)] in both orders → shows[0] has NO "seasons" key
        let body1 = TraktClient.historyBody([
            .show(tmdbID: 1396),
            .episode(showTMDBID: 1396, season: 1, episode: 1)
        ])
        XCTAssertEqual(body1.shows?.count, 1)
        XCTAssertEqual(body1.shows?[0].ids.tmdb, 1396)
        XCTAssertNil(body1.shows?[0].seasons)

        let body2 = TraktClient.historyBody([
            .episode(showTMDBID: 1396, season: 1, episode: 1),
            .show(tmdbID: 1396)
        ])
        XCTAssertEqual(body2.shows?.count, 1)
        XCTAssertEqual(body2.shows?[0].ids.tmdb, 1396)
        XCTAssertNil(body2.shows?[0].seasons)
    }

    func testHistoryBodyDeduplicationAndSorting() {
        // (b) duplicate .episode(1396,1,1) twice → exactly one episode object; duplicate .movie(603) twice → one movie object
        // Also: preserve deterministic sorted output for movie IDs and episodes.
        let body = TraktClient.historyBody([
            .episode(showTMDBID: 1396, season: 1, episode: 1),
            .episode(showTMDBID: 1396, season: 1, episode: 1),
            .movie(tmdbID: 603),
            .movie(tmdbID: 603),
            .movie(tmdbID: 100)
        ])
        XCTAssertEqual(body.shows?.count, 1)
        XCTAssertEqual(body.shows?[0].seasons?.count, 1)
        XCTAssertEqual(body.shows?[0].seasons?[0].episodes.count, 1)
        XCTAssertEqual(body.shows?[0].seasons?[0].episodes[0].number, 1)

        XCTAssertEqual(body.movies?.count, 2)
        XCTAssertEqual(body.movies?[0].ids.tmdb, 100) // sorted
        XCTAssertEqual(body.movies?[1].ids.tmdb, 603)
    }

    func testHistoryBodyWholeShowOnly() {
        // (c) ".show with no seasons marks the whole show" behavior
        let body = TraktClient.historyBody([.show(tmdbID: 1396)])
        XCTAssertEqual(body.shows?.count, 1)
        XCTAssertEqual(body.shows?[0].ids.tmdb, 1396)
        XCTAssertNil(body.shows?[0].seasons)
    }

    func testWatchlistDecodes() async throws {
        MockURLProtocol.setHandler { _ in
            .json("""
            [{"rank":1,"type":"movie",
              "movie":{"title":"Dune","year":2021,
                       "ids":{"trakt":1,"slug":"dune-2021","tmdb":438631}}},
             {"rank":2,"type":"show",
              "show":{"title":"Severance","year":2022,
                       "ids":{"trakt":2,"slug":"severance","tmdb":95396}}}]
            """)
        }
        let client = makeClient(tokens: tok())
        let entries = try await client.watchlist()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].movie?.ids.tmdb, 438631)
        XCTAssertEqual(entries[1].show?.title, "Severance")
    }

    func testTrendingMoviesIsUnauthenticated() async throws {
        nonisolated(unsafe) var seen: URLRequest?
        MockURLProtocol.setHandler { request in
            seen = request
            return .json("""
            [{"watchers":42,"movie":{"title":"Dune","year":2021,
              "ids":{"trakt":1,"slug":"dune-2021","tmdb":438631}}}]
            """)
        }
        let client = makeClient(tokens: nil)     // no OAuth tokens at all
        let entries = try await client.trendingMovies()
        XCTAssertEqual(entries.first?.watchers, 42)
        XCTAssertEqual(seen?.url?.path, "/movies/trending")
        XCTAssertNil(seen?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "trakt-api-key"), "cid")
    }

    func testTrendingShowsPath() async throws {
        nonisolated(unsafe) var seen: URLRequest?
        MockURLProtocol.setHandler { request in
            seen = request
            return .json("[]")
        }
        _ = try await makeClient(tokens: nil).trendingShows()
        XCTAssertEqual(seen?.url?.path, "/shows/trending")
    }

    func testTrendingMoviesCaches() async throws {
        let cache = MetadataCache(directory: nil)
        await cache.clear()
        
        let client = makeClient(tokens: nil)
        client.cache = cache
        
        nonisolated(unsafe) var requestCount = 0
        MockURLProtocol.setHandler { _ in
            requestCount += 1
            return .json("""
            [{"watchers":42,"movie":{"title":"Dune","year":2021,
              "ids":{"trakt":1,"slug":"dune-2021","tmdb":438631}}}]
            """)
        }
        
        let entries1 = try await client.trendingMovies()
        XCTAssertEqual(entries1.first?.watchers, 42)
        XCTAssertEqual(requestCount, 1)
        
        // Next request should hit cache and not trigger a URL protocol request
        let entries2 = try await client.trendingMovies()
        XCTAssertEqual(entries2.first?.watchers, 42)
        XCTAssertEqual(requestCount, 1)
    }

    func testTrendingMoviesBypassCache() async throws {
        let cache = MetadataCache(directory: nil)
        await cache.clear()
        
        let client = makeClient(tokens: nil)
        client.cache = cache
        
        let key = "trakt:/movies/trending"
        let oldPayload = """
        [{"watchers":10,"movie":{"title":"Old Movie","year":2020,"ids":{"trakt":2,"slug":"old-movie","tmdb":12345}}}]
        """
        await cache.store(oldPayload.data(using: .utf8)!, for: key)
        
        nonisolated(unsafe) var requestCount = 0
        MockURLProtocol.setHandler { _ in
            requestCount += 1
            return .json("""
            [{"watchers":99,"movie":{"title":"New Movie","year":2026,"ids":{"trakt":3,"slug":"new-movie","tmdb":67890}}}]
            """)
        }
        
        let entries = try await client.trendingMovies(bypassCache: true)
        XCTAssertEqual(entries.first?.watchers, 99)
        XCTAssertEqual(requestCount, 1)
        
        if let cachedData = await cache.data(for: key, ttl: 30 * 60) {
            let decoded = try TraktClient.decoder.decode([TraktTrendingEntry].self, from: cachedData)
            XCTAssertEqual(decoded.first?.watchers, 99)
            XCTAssertEqual(decoded.first?.movie?.title, "New Movie")
        } else {
            XCTFail("Cache should hold the fresh payload")
        }
    }

    func testAddToWatchlistMovieBody() async throws {
        nonisolated(unsafe) var capturedPath: String?
        nonisolated(unsafe) var capturedMethod: String?
        nonisolated(unsafe) var capturedAuth: String?
        nonisolated(unsafe) var capturedBody: Data?
        MockURLProtocol.setHandler { req in
            capturedPath = req.url?.path
            capturedMethod = req.httpMethod
            capturedAuth = req.value(forHTTPHeaderField: "Authorization")
            capturedBody = req.bodyData
            return .json("{}", status: 201)
        }
        try await makeClient(tokens: tok()).addToWatchlist(tmdbID: 603, isShow: false)
        XCTAssertEqual(capturedPath, "/sync/watchlist")
        XCTAssertEqual(capturedMethod, "POST")
        XCTAssertEqual(capturedAuth, "Bearer at")
        let json = try JSONSerialization.jsonObject(
            with: XCTUnwrap(capturedBody)) as! [String: Any]
        let movies = json["movies"] as! [[String: Any]]
        XCTAssertEqual(movies.count, 1)
        XCTAssertEqual(movies[0]["ids"] as! [String: Int], ["tmdb": 603])
        XCTAssertNil(json["shows"])
    }

    func testRemoveFromWatchlistShowBody() async throws {
        nonisolated(unsafe) var capturedPath: String?
        nonisolated(unsafe) var capturedMethod: String?
        nonisolated(unsafe) var capturedAuth: String?
        nonisolated(unsafe) var capturedBody: Data?
        MockURLProtocol.setHandler { req in
            capturedPath = req.url?.path
            capturedMethod = req.httpMethod
            capturedAuth = req.value(forHTTPHeaderField: "Authorization")
            capturedBody = req.bodyData
            return .json("{}", status: 200)
        }
        try await makeClient(tokens: tok()).removeFromWatchlist(tmdbID: 1396, isShow: true)
        XCTAssertEqual(capturedPath, "/sync/watchlist/remove")
        XCTAssertEqual(capturedMethod, "POST")
        XCTAssertEqual(capturedAuth, "Bearer at")
        let json = try JSONSerialization.jsonObject(
            with: XCTUnwrap(capturedBody)) as! [String: Any]
        let shows = json["shows"] as! [[String: Any]]
        XCTAssertEqual(shows[0]["ids"] as! [String: Int], ["tmdb": 1396])
        XCTAssertNil(json["movies"])
    }

    func testWatchlistWriteWithoutTokensThrowsUnauthorized() async {
        do {
            try await makeClient(tokens: nil).addToWatchlist(tmdbID: 1, isShow: false)
            XCTFail("expected unauthorized")
        } catch let e as TraktError {
            guard case .unauthorized = e else { return XCTFail("wrong error: \(e)") }
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testRecommendedMoviesRequestAndDecode() async throws {
        nonisolated(unsafe) var capturedURL: URL?
        nonisolated(unsafe) var capturedAuth: String?
        MockURLProtocol.setHandler { req in
            capturedURL = req.url
            capturedAuth = req.value(forHTTPHeaderField: "Authorization")
            return .json(#"[{"title":"Inception","year":2010,"ids":{"trakt":16662,"tmdb":27205}}]"#)
        }
        let recs = try await makeClient(tokens: tok()).recommendedMovies()
        XCTAssertEqual(recs.count, 1)
        XCTAssertEqual(recs[0].title, "Inception")
        XCTAssertEqual(recs[0].ids.tmdb, 27205)
        XCTAssertEqual(recs[0].ids.trakt, 16662)
        let url = try XCTUnwrap(capturedURL)
        XCTAssertEqual(url.path, "/recommendations/movies")
        // request() sorts query keys alphabetically.
        XCTAssertEqual(url.query, "ignore_collected=true&ignore_watchlisted=true&limit=100")
        XCTAssertEqual(capturedAuth, "Bearer at")
    }

    func testRecommendedShowsPathAndLimit() async throws {
        nonisolated(unsafe) var capturedURL: URL?
        MockURLProtocol.setHandler { req in
            capturedURL = req.url
            return .json("[]")
        }
        _ = try await makeClient(tokens: tok()).recommendedShows(limit: 25)
        let url = try XCTUnwrap(capturedURL)
        XCTAssertEqual(url.path, "/recommendations/shows")
        XCTAssertEqual(url.query, "ignore_collected=true&ignore_watchlisted=true&limit=25")
    }

    func testHideRecommendationDeletes() async throws {
        nonisolated(unsafe) var capturedPath: String?
        nonisolated(unsafe) var capturedMethod: String?
        MockURLProtocol.setHandler { req in
            capturedPath = req.url?.path
            capturedMethod = req.httpMethod
            return .json("", status: 204)
        }
        try await makeClient(tokens: tok()).hideRecommendation(traktID: 16662, isShow: false)
        XCTAssertEqual(capturedPath, "/recommendations/movies/16662")
        XCTAssertEqual(capturedMethod, "DELETE")

        try await makeClient(tokens: tok()).hideRecommendation(traktID: 1390, isShow: true)
        XCTAssertEqual(capturedPath, "/recommendations/shows/1390")
    }

    func testRecommendationsWithoutTokensThrowsUnauthorized() async {
        do {
            try await makeClient(tokens: nil).recommendedMovies()
            XCTFail("expected unauthorized")
        } catch let e as TraktError {
            guard case .unauthorized = e else { return XCTFail("wrong error: \(e)") }
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testFavoritesDecodes() async throws {
        nonisolated(unsafe) var capturedPath: String?
        MockURLProtocol.setHandler { req in
            capturedPath = req.url?.path
            return .json(#"""
            [{"rank":1,"id":101,"listed_at":"2026-08-01T00:00:00.000Z","type":"movie",
              "movie":{"title":"Heat","year":1995,"ids":{"trakt":818,"tmdb":949}}},
             {"rank":2,"id":102,"listed_at":"2026-08-02T00:00:00.000Z","type":"show",
              "show":{"title":"The Wire","year":2002,"ids":{"trakt":1438,"tmdb":1438}}}]
            """#)
        }
        let favs = try await makeClient(tokens: tok()).favorites()
        XCTAssertEqual(capturedPath, "/sync/favorites")
        XCTAssertEqual(favs.count, 2)
        XCTAssertEqual(favs[0].type, "movie")
        XCTAssertEqual(favs[0].movie?.ids.tmdb, 949)
        XCTAssertEqual(favs[1].show?.ids.tmdb, 1438)
    }

    func testAddToFavoritesMovieBody() async throws {
        nonisolated(unsafe) var capturedPath: String?
        nonisolated(unsafe) var capturedBody: Data?
        MockURLProtocol.setHandler { req in
            capturedPath = req.url?.path
            capturedBody = req.bodyData
            return .json("{}", status: 201)
        }
        try await makeClient(tokens: tok()).addToFavorites(tmdbID: 603, isShow: false)
        XCTAssertEqual(capturedPath, "/sync/favorites")
        let json = try JSONSerialization.jsonObject(
            with: XCTUnwrap(capturedBody)) as! [String: Any]
        let movies = json["movies"] as! [[String: Any]]
        XCTAssertEqual(movies[0]["ids"] as! [String: Int], ["tmdb": 603])
        XCTAssertNil(json["shows"])
    }

    func testRemoveFromFavoritesShowBody() async throws {
        nonisolated(unsafe) var capturedPath: String?
        nonisolated(unsafe) var capturedBody: Data?
        MockURLProtocol.setHandler { req in
            capturedPath = req.url?.path
            capturedBody = req.bodyData
            return .json("{}")
        }
        try await makeClient(tokens: tok()).removeFromFavorites(tmdbID: 1396, isShow: true)
        XCTAssertEqual(capturedPath, "/sync/favorites/remove")
        let json = try JSONSerialization.jsonObject(
            with: XCTUnwrap(capturedBody)) as! [String: Any]
        let shows = json["shows"] as! [[String: Any]]
        XCTAssertEqual(shows[0]["ids"] as! [String: Int], ["tmdb": 1396])
        XCTAssertNil(json["movies"])
    }
}



