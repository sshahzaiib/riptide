import XCTest
import SwiftData
@testable import StreamCore

@MainActor
final class BackupTests: XCTestCase {
    private func entry(torrentID: String, filename: String = "Movie.2020.mkv") -> LibraryFileEntry {
        LibraryFileEntry(torrentID: torrentID, fileIndex: 0, filename: filename, bytes: 100,
                         added: "2026-06-01T00:00:00.000Z", link: "https://real-debrid.com/d/X")
    }

    // upsert deletes items absent from `entries`, so match all torrents in one call
    private func matched(_ store: LibraryStore, _ ids: [String: Int]) throws {
        _ = try store.upsert(entries: ids.keys.sorted().map { entry(torrentID: $0, filename: "Movie\(ids[$0]!).2020.mkv") })
        for (id, tmdb) in ids {
            try store.applyMatch(itemKey: "\(id)#0", tmdbID: tmdb, mediaKind: "movie",
                                 posterPath: nil, overview: nil, rating: nil)
        }
    }

    func testHistoryRoundTrip() throws {
        let store = try LibraryStore.inMemory()
        try matched(store, ["T1": 1, "T2": 2])
        try store.saveProgress(itemKey: "T1#0", position: 10, duration: 100)
        try store.saveProgress(itemKey: "T2#0", position: 50, duration: 100)
        let dtos = try store.exportHistory()
        let fresh = try LibraryStore.inMemory()
        XCTAssertEqual(try fresh.importHistory(dtos), 2)
        let a = try store.history(), b = try fresh.history()
        XCTAssertEqual(a.map(\.key), b.map(\.key))
        XCTAssertEqual(a.map(\.progress), b.map(\.progress))
    }

    func testImportHistoryNewestWins() throws {
        let store = try LibraryStore.inMemory()
        try matched(store, ["T1": 1])
        try store.saveProgress(itemKey: "T1#0", position: 50, duration: 100)
        let local = try XCTUnwrap(store.exportHistory().first)
        func dto(_ delta: TimeInterval, _ p: Double) -> HistoryEntryDTO {
            var d = local; d.lastWatchedAt = local.lastWatchedAt.addingTimeInterval(delta); d.progress = p
            return d
        }
        XCTAssertEqual(try store.importHistory([dto(-60, 0.1)]), 0)
        XCTAssertEqual(try store.history()[0].progress, 0.5, accuracy: 0.0001)
        XCTAssertEqual(try store.importHistory([dto(60, 0.1)]), 1)
        XCTAssertEqual(try store.history()[0].progress, 0.1, accuracy: 0.0001)
    }

    func testImportWatchStatesNewestWins() throws {
        let store = try LibraryStore.inMemory()
        try matched(store, ["T1": 1])
        try store.saveProgress(itemKey: "T1#0", position: 50, duration: 100)
        let local = try XCTUnwrap(store.exportWatchStates().first)
        func dto(_ delta: TimeInterval, _ p: Double) -> WatchStateDTO {
            var d = local; d.lastWatchedAt = local.lastWatchedAt.addingTimeInterval(delta); d.positionSeconds = p
            return d
        }
        XCTAssertEqual(try store.importWatchStates([dto(-60, 10)]), 0)
        XCTAssertEqual(try store.exportWatchStates()[0].positionSeconds, 50, accuracy: 0.0001)
        XCTAssertEqual(try store.importWatchStates([dto(60, 10)]), 1)
        XCTAssertEqual(try store.exportWatchStates()[0].positionSeconds, 10, accuracy: 0.0001)
    }

    func testWatchStateRoundTrip() throws {
        let store = try LibraryStore.inMemory()
        try matched(store, ["T1": 1])
        try store.saveProgress(itemKey: "T1#0", position: 10, duration: 100)
        let fresh = try LibraryStore.inMemory()
        XCTAssertEqual(try fresh.importWatchStates(store.exportWatchStates()), 1)
        XCTAssertEqual(try fresh.continueWatching().map(\.itemKey), ["T1#0"])
    }
}
