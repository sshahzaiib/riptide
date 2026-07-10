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
}
