import XCTest
import SwiftData
@testable import StreamCore

@MainActor
final class LibraryStoreTests: XCTestCase {
    private func torrent(id: String, filename: String,
                         added: String = "2026-06-01T00:00:00.000Z",
                         links: [String] = ["https://real-debrid.com/d/X"]) -> TorrentListItem {
        TorrentListItem(id: id, filename: filename, bytes: 100, progress: 100,
                        status: "downloaded", added: added, links: links, ended: nil)
    }

    func testUpsertInsertsAndParses() throws {
        let store = try LibraryStore.inMemory()
        let summary = try store.upsert(torrents: [
            torrent(id: "T1", filename: "The.Matrix.1999.1080p.BluRay.mkv"),
            torrent(id: "T2", filename: "Breaking.Bad.S05E14.720p.HDTV.mkv"),
        ])
        XCTAssertEqual(summary, UpsertSummary(inserted: 2, updated: 0, deleted: 0))
        let items = try store.items()
        XCTAssertEqual(items.count, 2)
        let matrix = try XCTUnwrap(items.first { $0.torrentID == "T1" })
        XCTAssertEqual(matrix.title, "The Matrix")
        XCTAssertEqual(matrix.year, 1999)
        XCTAssertEqual(matrix.mediaKind, "movie")
        let bb = try XCTUnwrap(items.first { $0.torrentID == "T2" })
        XCTAssertEqual(bb.season, 5)
        XCTAssertEqual(bb.episode, 14)
        XCTAssertEqual(bb.mediaKind, "episode")
    }

    func testUpsertIsIdempotentAndDiffs() throws {
        let store = try LibraryStore.inMemory()
        _ = try store.upsert(torrents: [torrent(id: "T1", filename: "A.2020.mkv"),
                                        torrent(id: "T2", filename: "B.2021.mkv")])
        // Second sync: T1 unchanged, T2 vanished, T3 new.
        let summary = try store.upsert(torrents: [torrent(id: "T1", filename: "A.2020.mkv"),
                                                  torrent(id: "T3", filename: "C.2022.mkv")])
        XCTAssertEqual(summary, UpsertSummary(inserted: 1, updated: 0, deleted: 1))
        XCTAssertEqual(Set(try store.items().map(\.torrentID)), ["T1", "T3"])
    }

    func testUpsertUpdatesChangedFilename() throws {
        let store = try LibraryStore.inMemory()
        _ = try store.upsert(torrents: [torrent(id: "T1", filename: "old.mkv")])
        let summary = try store.upsert(torrents: [torrent(id: "T1", filename: "A.2020.1080p.mkv")])
        XCTAssertEqual(summary, UpsertSummary(inserted: 0, updated: 1, deleted: 0))
        let item = try XCTUnwrap(try store.items().first)
        XCTAssertEqual(item.title, "A")
        XCTAssertEqual(item.year, 2020)
    }

    func testApplyMatch() throws {
        let store = try LibraryStore.inMemory()
        _ = try store.upsert(torrents: [torrent(id: "T1", filename: "The.Matrix.1999.mkv")])
        try store.applyMatch(torrentID: "T1", tmdbID: 603, mediaKind: "movie",
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
        XCTAssertEqual(cw[0].positionSeconds, 300)
        XCTAssertFalse(cw[0].finished)

        // Update overwrites, doesn't duplicate.
        try store.saveProgress(itemKey: "T1#0", position: 600, duration: 7200)
        cw = try store.continueWatching()
        XCTAssertEqual(cw.count, 1)
        XCTAssertEqual(cw[0].positionSeconds, 600)

        // >= 95% marks finished and leaves Continue Watching.
        try store.saveProgress(itemKey: "T1#0", position: 6900, duration: 7200)
        XCTAssertTrue(try store.continueWatching().isEmpty)
    }

    func testContinueWatchingOrdersByRecency() throws {
        let store = try LibraryStore.inMemory()
        try store.saveProgress(itemKey: "old", position: 10, duration: 100)
        try store.saveProgress(itemKey: "new", position: 10, duration: 100)
        // "new" was written later -> more recent lastWatchedAt -> first.
        XCTAssertEqual(try store.continueWatching().map(\.itemKey), ["new", "old"])
    }

    func testUpsertIgnoresDuplicateIDsInInput() throws {
        let store = try LibraryStore.inMemory()
        let summary = try store.upsert(torrents: [
            torrent(id: "T1", filename: "A.2020.mkv"),
            torrent(id: "T1", filename: "A.2020.mkv"),
        ])
        XCTAssertEqual(summary, UpsertSummary(inserted: 1, updated: 0, deleted: 0))
        XCTAssertEqual(try store.items().count, 1)
    }

    func testDeletingItemRemovesItsWatchStates() throws {
        let store = try LibraryStore.inMemory()
        _ = try store.upsert(torrents: [torrent(id: "T1", filename: "A.2020.mkv"),
                                        torrent(id: "T2", filename: "B.2021.mkv")])
        try store.saveProgress(itemKey: "T2#0", position: 100, duration: 7200)
        try store.saveProgress(itemKey: "T1#0", position: 100, duration: 7200)
        _ = try store.upsert(torrents: [torrent(id: "T1", filename: "A.2020.mkv")])  // T2 vanished
        XCTAssertEqual(try store.continueWatching().map(\.itemKey), ["T1#0"])
    }
}
