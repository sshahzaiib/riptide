import XCTest
@testable import StreamCore

@MainActor
final class UpNextBuilderTests: XCTestCase {
    private func watchedShow(tmdb: Int, trakt: Int = 1, watchedAt: String) -> TraktWatchedShow {
        try! TraktClient.decoder.decode(TraktWatchedShow.self, from: Data(#"""
        {"last_watched_at":"\#(watchedAt)","show":{"ids":{"trakt":\#(trakt),"tmdb":\#(tmdb)}}}
        """#.utf8))
    }

    private func progress(nextSeason: Int?, nextNumber: Int?, tmdb: Int = 9) -> TraktShowProgress {
        let next = nextSeason.map {
            #","next_episode":{"season":\#($0),"number":\#(nextNumber!),"title":"Ep","ids":{"tmdb":\#(tmdb)}}"#
        } ?? #","next_episode":null"#
        return try! TraktClient.decoder.decode(TraktShowProgress.self,
                                               from: Data(#"{"seasons":[]\#(next)}"#.utf8))
    }

    private func playbackEntry(json: String) -> TraktPlaybackEntry {
        try! TraktClient.decoder.decode(TraktPlaybackEntry.self, from: Data(json.utf8))
    }

    func testShortlistSortsFiltersAndCaps() {
        let shows = [watchedShow(tmdb: 1, watchedAt: "2026-08-01T00:00:00.000Z"),
                     watchedShow(tmdb: 2, watchedAt: "2026-08-03T00:00:00.000Z"),
                     watchedShow(tmdb: 3, watchedAt: "2026-08-02T00:00:00.000Z")]
        let out = UpNextBuilder.shortlist(watched: shows, hiddenTMDBIDs: [3], cap: 2)
        XCTAssertEqual(out.map { $0.show.ids.tmdb }, [2, 1])   // newest first, 3 hidden
    }

    func testBuildOrdersPlaybackBeforeShowsAndDedupes() {
        let pausedEp = playbackEntry(json: #"""
        {"progress":42.5,"paused_at":"2026-08-05T00:00:00.000Z","type":"episode",
         "show":{"ids":{"tmdb":10}},"episode":{"season":1,"number":4}}
        """#)
        let pausedMovie = playbackEntry(json: #"""
        {"progress":10.0,"paused_at":"2026-08-06T00:00:00.000Z","type":"movie",
         "movie":{"ids":{"tmdb":603}}}
        """#)
        let items = UpNextBuilder.build(
            playback: [pausedEp, pausedMovie],
            progressByShow: [
                (watchedShow(tmdb: 10, watchedAt: "2026-08-04T00:00:00.000Z"),
                 progress(nextSeason: 1, nextNumber: 5)),        // deduped: playback covers show 10
                (watchedShow(tmdb: 20, watchedAt: "2026-08-03T00:00:00.000Z"),
                 progress(nextSeason: 2, nextNumber: 1)),
                (watchedShow(tmdb: 30, watchedAt: "2026-08-02T00:00:00.000Z"),
                 progress(nextSeason: nil, nextNumber: nil)),    // completed: dropped
            ])
        XCTAssertEqual(items.map(\.tmdbID), [603, 10, 20])       // newest paused first, then next-eps
        XCTAssertEqual(items[0].isShow, false)
        XCTAssertEqual(items[0].progressPercent, 10.0)
        XCTAssertEqual(items[1].season, 1); XCTAssertEqual(items[1].number, 4)
        XCTAssertEqual(items[2].season, 2); XCTAssertEqual(items[2].number, 1)
        XCTAssertNil(items[2].progressPercent)
    }

    func testBuildKeepsOnlyNewestPausedEpisodePerShow() {
        let newer = playbackEntry(json: #"""
        {"progress":42.5,"paused_at":"2026-08-05T00:00:00.000Z","type":"episode",
         "show":{"ids":{"tmdb":10}},"episode":{"season":1,"number":4}}
        """#)
        let older = playbackEntry(json: #"""
        {"progress":90.0,"paused_at":"2026-08-01T00:00:00.000Z","type":"episode",
         "show":{"ids":{"tmdb":10}},"episode":{"season":1,"number":3}}
        """#)
        let items = UpNextBuilder.build(playback: [older, newer], progressByShow: [])
        XCTAssertEqual(items.count, 1)                 // no duplicate media ids
        XCTAssertEqual(items[0].number, 4)             // newest pausedAt wins
    }

    func testBuildSkipsEntriesWithoutTMDBIDs() {
        let noID = playbackEntry(json: #"""
        {"progress":50.0,"paused_at":"2026-08-05T00:00:00.000Z","type":"movie","movie":{"ids":{"trakt":1}}}
        """#)
        XCTAssertTrue(UpNextBuilder.build(playback: [noID], progressByShow: []).isEmpty)
    }
}
