import XCTest
import SwiftData
@testable import StreamCore

@MainActor
final class LibraryStoreTests: XCTestCase {
    private func entry(torrentID: String, fileIndex: Int = 0, filename: String,
                       bytes: Int64 = 100,
                       added: String = "2026-06-01T00:00:00.000Z",
                       link: String = "https://real-debrid.com/d/X") -> LibraryFileEntry {
        LibraryFileEntry(torrentID: torrentID, fileIndex: fileIndex,
                         filename: filename, bytes: bytes, added: added, link: link)
    }

    func testUpsertInsertsAndParses() throws {
        let store = try LibraryStore.inMemory()
        let summary = try store.upsert(entries: [
            entry(torrentID: "T1", filename: "The.Matrix.1999.1080p.BluRay.mkv"),
            entry(torrentID: "T2", fileIndex: 3,
                  filename: "Breaking.Bad.S05E14.720p.HDTV.mkv"),
        ])
        XCTAssertEqual(summary, UpsertSummary(inserted: 2, updated: 0, deleted: 0))
        let items = try store.items()
        let matrix = try XCTUnwrap(items.first { $0.itemKey == "T1#0" })
        XCTAssertEqual(matrix.title, "The Matrix")
        XCTAssertEqual(matrix.mediaKind, "movie")
        let bb = try XCTUnwrap(items.first { $0.itemKey == "T2#3" })
        XCTAssertEqual(bb.season, 5)
        XCTAssertEqual(bb.episode, 14)
        XCTAssertEqual(bb.fileIndex, 3)
        XCTAssertEqual(bb.mediaKind, "episode")
    }

    func testUpsertIsIdempotentDiffsAndDedupes() throws {
        let store = try LibraryStore.inMemory()
        _ = try store.upsert(entries: [entry(torrentID: "T1", filename: "A.2020.mkv"),
                                       entry(torrentID: "T2", filename: "B.2021.mkv")])
        // Second sync: T1 unchanged (plus a duplicate), T2 vanished, T3 new.
        let summary = try store.upsert(entries: [
            entry(torrentID: "T1", filename: "A.2020.mkv"),
            entry(torrentID: "T1", filename: "A.2020.mkv"),
            entry(torrentID: "T3", filename: "C.2022.mkv"),
        ])
        XCTAssertEqual(summary, UpsertSummary(inserted: 1, updated: 0, deleted: 1))
        XCTAssertEqual(Set(try store.items().map(\.itemKey)), ["T1#0", "T3#0"])
    }

    func testUpsertUpdatesChangedFilenameAndClearsMatch() throws {
        let store = try LibraryStore.inMemory()
        _ = try store.upsert(entries: [entry(torrentID: "T1", filename: "old.mkv")])
        try store.applyMatch(itemKey: "T1#0", tmdbID: 1, mediaKind: "movie",
                             posterPath: "/x.jpg", overview: "", rating: 5)
        let summary = try store.upsert(entries: [entry(torrentID: "T1",
                                                       filename: "A.2020.1080p.mkv")])
        XCTAssertEqual(summary, UpsertSummary(inserted: 0, updated: 1, deleted: 0))
        let item = try XCTUnwrap(try store.items().first)
        XCTAssertEqual(item.title, "A")
        XCTAssertNil(item.tmdbID)          // stale match cleared
    }

    func testDeletingItemRemovesItsWatchState() throws {
        let store = try LibraryStore.inMemory()
        _ = try store.upsert(entries: [entry(torrentID: "T1", filename: "A.2020.mkv"),
                                       entry(torrentID: "T2", filename: "B.2021.mkv")])
        try store.saveProgress(itemKey: "T2#0", position: 100, duration: 7200)
        try store.saveProgress(itemKey: "T1#0", position: 100, duration: 7200)
        _ = try store.upsert(entries: [entry(torrentID: "T1", filename: "A.2020.mkv")])
        XCTAssertEqual(try store.continueWatching().map(\.itemKey), ["T1#0"])
    }

    func testDeleteByTorrentIDRemovesItemsAndWatchState() throws {
        let store = try LibraryStore.inMemory()
        _ = try store.upsert(entries: [entry(torrentID: "T1", filename: "A.2020.mkv"),
                                       entry(torrentID: "T2", filename: "B.2021.mkv")])
        try store.saveProgress(itemKey: "T1#0", position: 100, duration: 7200)
        try store.saveProgress(itemKey: "T2#0", position: 100, duration: 7200)
        try store.delete(torrentID: "T1")
        XCTAssertEqual(try store.items().map(\.itemKey), ["T2#0"])
        XCTAssertEqual(try store.allWatchStates().map(\.itemKey), ["T2#0"])
    }

    func testEntryCountsAndCachedEntries() throws {
        let store = try LibraryStore.inMemory()
        let originals = [
            entry(torrentID: "T1", fileIndex: 0, filename: "S01E01.mkv", link: "L0"),
            entry(torrentID: "T1", fileIndex: 1, filename: "S01E02.mkv", link: "L1"),
            entry(torrentID: "T2", filename: "movie.mkv"),
        ]
        _ = try store.upsert(entries: originals)
        XCTAssertEqual(try store.entryCounts(), ["T1": 2, "T2": 1])
        let cached = try store.cachedEntries(torrentID: "T1")
            .sorted { $0.fileIndex < $1.fileIndex }
        XCTAssertEqual(cached, Array(originals.prefix(2)))
    }

    func testApplyMatchByItemKey() throws {
        let store = try LibraryStore.inMemory()
        _ = try store.upsert(entries: [entry(torrentID: "T1", fileIndex: 2,
                                             filename: "The.Matrix.1999.mkv")])
        try store.applyMatch(itemKey: "T1#2", tmdbID: 603, mediaKind: "movie",
                             posterPath: "/p.jpg", overview: "A hacker...", rating: 8.2)
        let item = try XCTUnwrap(try store.items().first)
        XCTAssertEqual(item.tmdbID, 603)
        XCTAssertEqual(item.posterPath, "/p.jpg")
    }

    func testWatchProgressLifecycle() throws {
        let store = try LibraryStore.inMemory()
        try store.saveProgress(itemKey: "T1#0", position: 300, duration: 7200)
        var cw = try store.continueWatching()
        XCTAssertEqual(cw.map(\.itemKey), ["T1#0"])
        XCTAssertFalse(cw[0].finished)

        try store.saveProgress(itemKey: "T1#0", position: 600, duration: 7200)
        cw = try store.continueWatching()
        XCTAssertEqual(cw.count, 1)
        XCTAssertEqual(cw[0].positionSeconds, 600)

        try store.saveProgress(itemKey: "T1#0", position: 6900, duration: 7200)
        XCTAssertTrue(try store.continueWatching().isEmpty)
    }

    func testItemLookupByTMDBIdentity() throws {
        let store = try LibraryStore.inMemory()
        _ = try store.upsert(entries: [
            entry(torrentID: "T1", filename: "The.Matrix.1999.1080p.mkv"),
            entry(torrentID: "T2", fileIndex: 3, filename: "Breaking.Bad.S05E14.720p.mkv"),
        ])
        try store.applyMatch(itemKey: "T1#0", tmdbID: 603, mediaKind: "movie",
                             posterPath: nil, overview: nil, rating: nil)
        try store.applyMatch(itemKey: "T2#3", tmdbID: 1396, mediaKind: "episode",
                             posterPath: nil, overview: nil, rating: nil)

        XCTAssertEqual(try store.item(tmdbID: 603, season: nil, episode: nil)?.itemKey, "T1#0")
        XCTAssertEqual(try store.item(tmdbID: 1396, season: 5, episode: 14)?.itemKey, "T2#3")
        XCTAssertNil(try store.item(tmdbID: 1396, season: 5, episode: 99))   // other episode
        XCTAssertNil(try store.item(tmdbID: 603, season: 1, episode: 1))     // movie ≠ episode
        XCTAssertNil(try store.item(tmdbID: 42, season: nil, episode: nil))  // unknown id
    }

    func testADEntryKeyIsNamespacedAndRDKeyUnchanged() {
        let rd = LibraryFileEntry(torrentID: "T1", fileIndex: 0, filename: "a.mkv",
                                  bytes: 1, added: "", link: "l")
        let ad = LibraryFileEntry(service: "ad", torrentID: "77", fileIndex: 2,
                                  filename: "b.mkv", bytes: 1, added: "", link: "l")
        XCTAssertEqual(rd.itemKey, "T1#0")
        XCTAssertEqual(ad.itemKey, "ad#77#2")
    }

    func testUpsertProtectsFailedServicesOrphans() throws {
        let store = try LibraryStore.inMemory()
        let rd = LibraryFileEntry(torrentID: "T1", fileIndex: 0, filename: "Movie.2020.mkv",
                                  bytes: 1, added: "", link: "l1")
        let ad = LibraryFileEntry(service: "ad", torrentID: "77", fileIndex: 0,
                                  filename: "Show.S01E01.mkv", bytes: 2, added: "", link: "l2")
        _ = try store.upsert(entries: [rd, ad])
        // AD refresh failed: its orphan survives an upsert that omits it.
        _ = try store.upsert(entries: [rd], protecting: ["ad"])
        XCTAssertEqual(try store.items().count, 2)
        // AD refreshed fine and really is gone: orphan deleted.
        _ = try store.upsert(entries: [rd])
        XCTAssertEqual(try store.items().map(\.itemKey), ["T1#0"])
    }

    func testCachedEntriesByTorrentGroupsAndKeepsService() throws {
        let store = try LibraryStore.inMemory()
        let ad = LibraryFileEntry(service: "ad", torrentID: "77", fileIndex: 0,
                                  filename: "Show.S01E01.mkv", bytes: 2, added: "", link: "l2")
        _ = try store.upsert(entries: [ad])
        let grouped = try store.cachedEntriesByTorrent()
        XCTAssertEqual(grouped["77"], [ad])
    }

    func testUpsertClassifiesFlaggedEntriesAsExtras() throws {
        let store = try LibraryStore.inMemory()
        _ = try store.upsert(entries: [
            LibraryFileEntry(torrentID: "T1", fileIndex: 0,
                             filename: "Breaking_Bad_-_S01E01_Deleted_Scene_-_Walt.m4v",
                             bytes: 100, added: "2026-06-01T00:00:00.000Z",
                             link: "L0", isExtra: true),
            entry(torrentID: "T1", fileIndex: 1,
                  filename: "Breaking.Bad.S01E01.Pilot.mkv", link: "L1"),
        ])
        let items = try store.items()
        XCTAssertEqual(items.first { $0.itemKey == "T1#0" }?.mediaKind, "extra")
        XCTAssertEqual(items.first { $0.itemKey == "T1#1" }?.mediaKind, "episode")

        // The flag survives the cached-entries fast path (round-trip from mediaKind).
        let cached = try store.cachedEntries(torrentID: "T1")
            .sorted { $0.fileIndex < $1.fileIndex }
        XCTAssertTrue(cached[0].isExtra)
        XCTAssertFalse(cached[1].isExtra)
    }

    func testReclassifyExtrasFlipsPreDetectionRows() throws {
        let store = try LibraryStore.inMemory()
        // Simulate a library synced BEFORE detection existed: the deleted
        // scene was stored as a matched S01E01 "episode".
        _ = try store.upsert(entries: [
            entry(torrentID: "T1", fileIndex: 0,
                  filename: "Breaking_Bad_-_S01E01_Deleted_Scene_-_Walt.m4v"),
            entry(torrentID: "T1", fileIndex: 1,
                  filename: "Breaking.Bad.S01E01.Pilot.mkv", link: "L1"),
        ])
        try store.applyMatch(itemKey: "T1#0", tmdbID: 1396, mediaKind: "episode",
                             posterPath: "/p.jpg", overview: "x", rating: 8)

        XCTAssertEqual(try store.reclassifyExtras(), 1)
        let items = try store.items()
        let extra = try XCTUnwrap(items.first { $0.itemKey == "T1#0" })
        XCTAssertEqual(extra.mediaKind, "extra")
        XCTAssertNil(extra.tmdbID)                         // stale match cleared
        XCTAssertEqual(items.first { $0.itemKey == "T1#1" }?.mediaKind, "episode")
        XCTAssertEqual(try store.reclassifyExtras(), 0)    // idempotent
    }

    func testUpsertFlipsMediaKindWhenExtraFlagChanges() throws {
        let store = try LibraryStore.inMemory()
        
        // 1. upsert an entry with isExtra: false (default is false)
        let entry1 = entry(torrentID: "T1", fileIndex: 0, filename: "Breaking.Bad.S01E01.Pilot.mkv")
        _ = try store.upsert(entries: [entry1])
        XCTAssertEqual(try store.items().first?.mediaKind, "episode")
        
        // 2. re-upsert the SAME entry (same filename/link/bytes) with isExtra: true
        let entry2 = LibraryFileEntry(torrentID: "T1", fileIndex: 0, filename: "Breaking.Bad.S01E01.Pilot.mkv", bytes: 100, added: "2026-06-01T00:00:00.000Z", link: "https://real-debrid.com/d/X", isExtra: true)
        _ = try store.upsert(entries: [entry2])
        XCTAssertEqual(try store.items().first?.mediaKind, "extra")
        
        // 3. re-upsert again with isExtra: false
        _ = try store.upsert(entries: [entry1])
        XCTAssertEqual(try store.items().first?.mediaKind, "episode")
    }

    func testSetWatchedTogglesAndClearsProgress() throws {
        let store = try LibraryStore.inMemory()
        try store.saveProgress(itemKey: "T1#0", position: 300, duration: 7200)

        try store.setWatched(itemKey: "T1#0", watched: true)
        var state = try XCTUnwrap(try store.allWatchStates().first)
        XCTAssertTrue(state.finished)
        XCTAssertEqual(state.positionSeconds, 7200)        // jump to the end
        XCTAssertTrue(try store.continueWatching().isEmpty)

        try store.setWatched(itemKey: "T1#0", watched: false)
        state = try XCTUnwrap(try store.allWatchStates().first)
        XCTAssertFalse(state.finished)
        XCTAssertEqual(state.positionSeconds, 0)
        XCTAssertTrue(try store.continueWatching().isEmpty) // reset, not "in progress"
    }

    func testSetWatchedCreatesRowWithFreshTimestamp() throws {
        let store = try LibraryStore.inMemory()
        try store.setWatched(itemKey: "T9#0", watched: true)
        let state = try XCTUnwrap(try store.allWatchStates().first)
        XCTAssertTrue(state.finished)
        // Fresh timestamp ⇒ Trakt pull (strictly-newer-wins) can't overwrite it.
        XCTAssertGreaterThan(state.lastWatchedAt, Date(timeIntervalSinceNow: -60))
    }

    // MARK: nextEpisode(after:)

    /// Seed a show: each (season, episode, torrentID) becomes a matched
    /// episode of TMDB show `showID`.
    private func seedShow(_ store: LibraryStore, showID: Int = 100,
                          episodes: [(s: Int, e: Int, torrent: String)]) throws {
        let entries = episodes.enumerated().map { i, ep in
            entry(torrentID: ep.torrent, fileIndex: i,
                  filename: "Show.S\(String(format: "%02d", ep.s))E\(String(format: "%02d", ep.e)).1080p.mkv")
        }
        _ = try store.upsert(entries: entries)
        for entry in entries {
            try store.applyMatch(itemKey: entry.itemKey, tmdbID: showID,
                                 mediaKind: "episode", posterPath: nil,
                                 overview: nil, rating: nil)
        }
    }

    func testNextEpisodeSequential() throws {
        let store = try LibraryStore.inMemory()
        try seedShow(store, episodes: [(1, 1, "T1"), (1, 2, "T1"), (1, 3, "T1")])
        let next = try XCTUnwrap(try store.nextEpisode(after: "T1#0"))
        XCTAssertEqual(next.season, 1)
        XCTAssertEqual(next.episode, 2)
    }

    func testNextEpisodeSeasonRollover() throws {
        let store = try LibraryStore.inMemory()
        try seedShow(store, episodes: [(1, 8, "T1"), (2, 1, "T2")])
        let next = try XCTUnwrap(try store.nextEpisode(after: "T1#0"))
        XCTAssertEqual(next.season, 2)
        XCTAssertEqual(next.episode, 1)
    }

    func testNextEpisodeGapReturnsNil() throws {
        let store = try LibraryStore.inMemory()
        // E2 missing and no next-season E1: never skip a gap.
        try seedShow(store, episodes: [(1, 1, "T1"), (1, 3, "T1"), (2, 2, "T2")])
        XCTAssertNil(try store.nextEpisode(after: "T1#0"))
    }

    func testNextEpisodeGapDoesNotRolloverWhenLaterSameSeasonEpisodeOwned() throws {
        let store = try LibraryStore.inMemory()
        // E2 missing but S1E3 IS owned, and S2E1 is also owned. Rolling over
        // to S2E1 would silently skip S1E3 — must return nil instead.
        try seedShow(store, episodes: [(1, 1, "T1"), (1, 3, "T1"), (2, 1, "T2")])
        XCTAssertNil(try store.nextEpisode(after: "T1#0"))
    }

    func testPreviousEpisodeSequential() throws {
        let store = try LibraryStore.inMemory()
        try seedShow(store, episodes: [(1, 1, "T1"), (1, 2, "T1")])
        let prev = try XCTUnwrap(try store.previousEpisode(before: "T1#1"))
        XCTAssertEqual(prev.season, 1)
        XCTAssertEqual(prev.episode, 1)
    }

    func testPreviousEpisodeSeasonRollback() throws {
        let store = try LibraryStore.inMemory()
        // From S2E1 back to the highest owned episode of S1.
        try seedShow(store, episodes: [(1, 7, "T1"), (1, 8, "T1"), (2, 1, "T2")])
        let prev = try XCTUnwrap(try store.previousEpisode(before: "T2#2"))
        XCTAssertEqual(prev.season, 1)
        XCTAssertEqual(prev.episode, 8)
    }

    func testPreviousEpisodeGapReturnsNil() throws {
        let store = try LibraryStore.inMemory()
        // E2 missing: stepping back from E3 must not skip to E1.
        try seedShow(store, episodes: [(1, 1, "T1"), (1, 3, "T1")])
        XCTAssertNil(try store.previousEpisode(before: "T1#1"))
    }

    func testPreviousEpisodeAtStartReturnsNil() throws {
        let store = try LibraryStore.inMemory()
        try seedShow(store, episodes: [(1, 1, "T1")])
        XCTAssertNil(try store.previousEpisode(before: "T1#0"))
        // Movies and unmatched items have no previous episode.
        _ = try store.upsert(entries: [entry(torrentID: "M1", filename: "The.Matrix.1999.mkv")])
        XCTAssertNil(try store.previousEpisode(before: "M1#0"))
    }

    func testNextEpisodePrefersSamePack() throws {
        let store = try LibraryStore.inMemory()
        // E2 exists as a loose 4K file (T9) and inside the current pack (T1).
        try seedShow(store, episodes: [(1, 1, "T1"), (1, 2, "T9"), (1, 2, "T1")])
        let next = try XCTUnwrap(try store.nextEpisode(after: "T1#0"))
        XCTAssertEqual(next.torrentID, "T1")
    }

    func testNextEpisodeIgnoresOtherShowsAndMovies() throws {
        let store = try LibraryStore.inMemory()
        try seedShow(store, showID: 100, episodes: [(1, 1, "T1")])
        try seedShow(store, showID: 200, episodes: [(1, 2, "T5")])   // other show's E2
        XCTAssertNil(try store.nextEpisode(after: "T1#0"))
        // Movies and unmatched items have no next episode.
        _ = try store.upsert(entries: [entry(torrentID: "M1", filename: "The.Matrix.1999.mkv")])
        XCTAssertNil(try store.nextEpisode(after: "M1#0"))
        XCTAssertNil(try store.nextEpisode(after: "does-not-exist"))
    }

    private func matchAsShow(_ store: LibraryStore, keys: [String]) throws {
        for key in keys {
            try store.applyMatch(itemKey: key, tmdbID: 42, mediaKind: "episode",
                                 posterPath: nil, overview: nil, rating: nil)
        }
    }

    func testNextEpisodePackAffinityBeatsHistoryAndQuality() throws {
        let store = try LibraryStore.inMemory()
        _ = try store.upsert(entries: [
            entry(torrentID: "PACK", fileIndex: 0, filename: "Show.S01E01.720p.mkv"),
            entry(torrentID: "PACK", fileIndex: 1, filename: "Show.S01E02.720p.mkv"),
            entry(torrentID: "T4K", filename: "Show.S01E02.2160p.mkv"),
        ])
        try matchAsShow(store, keys: ["PACK#0", "PACK#1", "T4K#0"])
        try store.saveProgress(itemKey: "T4K#0", position: 10, duration: 100)
        XCTAssertEqual(try store.nextEpisode(after: "PACK#0")?.itemKey, "PACK#1")
    }

    func testNextEpisodeLastPlayedBeatsQualityAcrossPacks() throws {
        let store = try LibraryStore.inMemory()
        _ = try store.upsert(entries: [
            entry(torrentID: "CUR", filename: "Show.S01E01.720p.mkv"),
            entry(torrentID: "TSD", filename: "Show.S01E02.720p.mkv"),
            entry(torrentID: "T4K", filename: "Show.S01E02.2160p.mkv"),
        ])
        try matchAsShow(store, keys: ["CUR#0", "TSD#0", "T4K#0"])
        try store.saveProgress(itemKey: "TSD#0", position: 10, duration: 100)
        XCTAssertEqual(try store.nextEpisode(after: "CUR#0")?.itemKey, "TSD#0")
    }

    func testNextEpisodePicksBestQualityWithoutHistory() throws {
        let store = try LibraryStore.inMemory()
        _ = try store.upsert(entries: [
            entry(torrentID: "CUR", filename: "Show.S01E01.720p.mkv"),
            entry(torrentID: "TSD", filename: "Show.S01E02.720p.mkv"),
            entry(torrentID: "T4K", filename: "Show.S01E02.2160p.mkv"),
        ])
        try matchAsShow(store, keys: ["CUR#0", "TSD#0", "T4K#0"])
        XCTAssertEqual(try store.nextEpisode(after: "CUR#0")?.itemKey, "T4K#0")
    }
}


