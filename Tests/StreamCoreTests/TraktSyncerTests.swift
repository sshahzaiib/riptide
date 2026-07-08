import XCTest
@testable import StreamCore

@MainActor
final class TraktSyncerTests: XCTestCase {
    private var store: LibraryStore!
    private var client: TraktClient!

    override func setUp() async throws {
        store = try LibraryStore.inMemory()
        client = TraktClient(clientID: "cid", clientSecret: "cs",
                             tokens: TraktTokens(accessToken: "at", refreshToken: "rt",
                                                 createdAt: 0, expiresIn: 9999),
                             session: .mocked())
        // Library: one movie (tmdb 603), one episode S1E5 of show tmdb 1399.
        _ = try store.upsert(entries: [
            LibraryFileEntry(torrentID: "t1", fileIndex: 0,
                             filename: "The.Matrix.1999.1080p.BluRay.mkv",
                             bytes: 1, added: "2026-01-01T00:00:00Z", link: "l1"),
            LibraryFileEntry(torrentID: "t2", fileIndex: 3,
                             filename: "Game.of.Thrones.S01E05.1080p.mkv",
                             bytes: 1, added: "2026-01-01T00:00:00Z", link: "l2"),
        ])
        try store.applyMatch(itemKey: "t1#0", tmdbID: 603, mediaKind: "movie",
                             posterPath: nil, overview: nil, rating: nil)
        try store.applyMatch(itemKey: "t2#3", tmdbID: 1399, mediaKind: "episode",
                             posterPath: nil, overview: nil, rating: nil)
    }

    override func tearDown() {
        MockURLProtocol.setHandler(nil)
        super.tearDown()
    }

    private func respond(playback: String = "[]", watchedMovies: String = "[]",
                         watchedShows: String = "[]", gotProgress: String = "{\"seasons\":[]}") {
        MockURLProtocol.setHandler { req in
            let json: String = switch req.url!.path {
            case "/sync/playback": playback
            case "/sync/watched/movies": watchedMovies
            case "/sync/watched/shows": watchedShows
            case "/shows/1390/progress/watched": gotProgress
            default: "[]"
            }
            return .json(json)
        }
    }

    /// Shallow watched-shows entry for GoT (tmdb 1399, trakt 1390) — the live
    /// API returns no seasons; episode data comes from the progress endpoint.
    private let gotWatched =
        #"[{"last_watched_at":"2099-01-01T00:00:00.000Z","show":{"ids":{"tmdb":1399,"trakt":1390}}}]"#

    private func state(_ key: String) throws -> WatchState? {
        try store.allWatchStates().first { $0.itemKey == key }
    }

    func testPlaybackNewerThanLocalApplies() async throws {
        try store.saveProgress(itemKey: "t1#0", position: 100, duration: 4000) // now
        respond(playback: #"[{"progress":50.0,"paused_at":"2099-01-01T00:00:00.000Z","type":"movie","movie":{"ids":{"tmdb":603}}}]"#)
        let summary = try await TraktSyncer(client: client, store: store).pull()
        XCTAssertEqual(summary.playbackApplied, 1)
        XCTAssertEqual(try state("t1#0")?.positionSeconds, 2000) // 50% of 4000
        XCTAssertEqual(try state("t1#0")?.finished, false)
    }

    func testPlaybackOlderThanLocalSkipped() async throws {
        try store.saveProgress(itemKey: "t1#0", position: 100, duration: 4000) // now
        respond(playback: #"[{"progress":50.0,"paused_at":"2020-01-01T00:00:00.000Z","type":"movie","movie":{"ids":{"tmdb":603}}}]"#)
        let summary = try await TraktSyncer(client: client, store: store).pull()
        XCTAssertEqual(summary.playbackApplied, 0)
        XCTAssertEqual(try state("t1#0")?.positionSeconds, 100)
    }

    func testPlaybackWithoutLocalDurationSkipped() async throws {
        respond(playback: #"[{"progress":50.0,"paused_at":"2099-01-01T00:00:00.000Z","type":"movie","movie":{"ids":{"tmdb":603}}}]"#)
        let summary = try await TraktSyncer(client: client, store: store).pull()
        XCTAssertEqual(summary.playbackApplied, 0)
        XCTAssertNil(try state("t1#0"))
    }

    func testWatchedEpisodeMarksFinished() async throws {
        respond(watchedShows: gotWatched,
                gotProgress: #"{"seasons":[{"number":1,"episodes":[{"number":5,"completed":true,"last_watched_at":"2099-01-01T00:00:00.000Z"}]}]}"#)
        let summary = try await TraktSyncer(client: client, store: store).pull()
        XCTAssertEqual(summary.watchedApplied, 1)
        XCTAssertEqual(try state("t2#3")?.finished, true)
    }

    func testUncompletedEpisodeNotMarked() async throws {
        respond(watchedShows: gotWatched,
                gotProgress: #"{"seasons":[{"number":1,"episodes":[{"number":5,"completed":false,"last_watched_at":null}]}]}"#)
        let summary = try await TraktSyncer(client: client, store: store).pull()
        XCTAssertEqual(summary.watchedApplied, 0)
        XCTAssertNil(try state("t2#3"))
    }

    func testWatchedOlderThanLocalUnfinishedSkipped() async throws {
        try store.saveProgress(itemKey: "t2#3", position: 500, duration: 3000) // now, unfinished
        respond(watchedShows: gotWatched,
                gotProgress: #"{"seasons":[{"number":1,"episodes":[{"number":5,"completed":true,"last_watched_at":"2020-01-01T00:00:00.000Z"}]}]}"#)
        let summary = try await TraktSyncer(client: client, store: store).pull()
        XCTAssertEqual(summary.watchedApplied, 0)
        XCTAssertEqual(try state("t2#3")?.finished, false)
    }

    func testShowsNotInLibrarySkipProgressFetch() async throws {
        // Foreign show (tmdb 4607): no local episodes -> progress endpoint
        // must not be called at all.
        nonisolated(unsafe) var progressCalls = 0
        MockURLProtocol.setHandler { req in
            if req.url!.path.hasPrefix("/shows/") { progressCalls += 1 }
            if req.url!.path == "/sync/watched/shows" {
                return .json(#"[{"last_watched_at":"2099-01-01T00:00:00.000Z","show":{"ids":{"tmdb":4607,"trakt":4583}}}]"#)
            }
            return .json(req.url!.path == "/sync/playback" ? "[]" : "[]")
        }
        let summary = try await TraktSyncer(client: client, store: store).pull()
        XCTAssertEqual(summary.watchedApplied, 0)
        XCTAssertEqual(progressCalls, 0)
    }

    func testUnmatchedEntriesIgnored() async throws {
        respond(playback: #"[{"progress":50.0,"paused_at":"2099-01-01T00:00:00.000Z","type":"movie","movie":{"ids":{"tmdb":99999}}}]"#,
                watchedMovies: #"[{"movie":{"ids":{"tmdb":88888}},"last_watched_at":"2099-01-01T00:00:00.000Z"}]"#)
        let summary = try await TraktSyncer(client: client, store: store).pull()
        XCTAssertEqual(summary, TraktSyncer.Summary())
    }
}
