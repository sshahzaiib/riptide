import XCTest
import SwiftData
@testable import StreamCore

@MainActor
final class HistoryTests: XCTestCase {
    private func entry(torrentID: String, filename: String = "Movie.2020.mkv") -> LibraryFileEntry {
        LibraryFileEntry(torrentID: torrentID, fileIndex: 0, filename: filename, bytes: 100,
                         added: "2026-06-01T00:00:00.000Z", link: "https://real-debrid.com/d/X")
    }

    private func matched(_ store: LibraryStore, _ ids: [String], tmdb: Int = 42,
                         kind: String = "movie") throws {
        _ = try store.upsert(entries: ids.map { entry(torrentID: $0) })
        for id in ids {
            try store.applyMatch(itemKey: "\(id)#0", tmdbID: tmdb, mediaKind: kind,
                                 posterPath: nil, overview: nil, rating: nil)
        }
    }

    func testSaveProgressRecordsHistoryAndSurvivesDelete() throws {
        let store = try LibraryStore.inMemory()
        try matched(store, ["T1"])
        try store.saveProgress(itemKey: "T1#0", position: 600, duration: 7200)
        let h = try store.history()
        XCTAssertEqual(h.map(\.key), ["tmdb:42"])
        XCTAssertEqual(h[0].progress, 600.0 / 7200, accuracy: 0.0001)
        XCTAssertFalse(h[0].finished)
        try store.delete(torrentID: "T1")
        XCTAssertEqual(try store.history().count, 1)
    }

    func testDuplicateCopiesShareOneRow() throws {
        let store = try LibraryStore.inMemory()
        try matched(store, ["T1", "T2"])
        try store.saveProgress(itemKey: "T1#0", position: 10, duration: 100)
        try store.saveProgress(itemKey: "T2#0", position: 20, duration: 100)
        XCTAssertEqual(try store.history().count, 1)
    }

    func testSetUnwatchedKeepsHistoryRow() throws {
        let store = try LibraryStore.inMemory()
        try matched(store, ["T1"])
        try store.setWatched(itemKey: "T1#0", watched: true)
        var h = try store.history()
        XCTAssertTrue(h[0].finished)
        XCTAssertEqual(h[0].progress, 1)
        try store.setWatched(itemKey: "T1#0", watched: false)
        h = try store.history()
        XCTAssertEqual(h.count, 1)
        XCTAssertFalse(h[0].finished)
        XCTAssertEqual(h[0].progress, 0)
    }

    func testRecordHistoryIgnoresOlderUpdate() throws {
        let store = try LibraryStore.inMemory()
        try matched(store, ["T1"])
        let item = try XCTUnwrap(store.items().first)
        let now = Date.now
        try store.recordHistory(item: item, progress: 0.5, finished: false, at: now)
        try store.recordHistory(item: item, progress: 0.1, finished: false, at: now.addingTimeInterval(-3600))
        let h = try store.history()
        XCTAssertEqual(h[0].progress, 0.5)
        XCTAssertEqual(h[0].lastWatchedAt, now)
    }

    func testRemoteProgressDoesNotClearFinished() throws {
        let store = try LibraryStore.inMemory()
        try matched(store, ["T1"])
        try store.setWatched(itemKey: "T1#0", watched: true)
        try store.applyRemoteProgress(itemKey: "T1#0", position: 10, duration: 100,
                                      watchedAt: .now.addingTimeInterval(60))
        let h = try store.history()
        XCTAssertTrue(h[0].finished)
        XCTAssertEqual(h[0].progress, 0.1, accuracy: 0.0001)
    }

    func testExtrasNotRecorded() throws {
        let store = try LibraryStore.inMemory()
        try matched(store, ["T1"])
        let item = try XCTUnwrap(store.items().first)
        item.mediaKind = "extra"
        try store.context.save()
        try store.saveProgress(itemKey: "T1#0", position: 10, duration: 100)
        XCTAssertTrue(try store.history().isEmpty)
    }

    func testBackfillFromWatchStates() throws {
        let store = try LibraryStore.inMemory()
        _ = try store.upsert(entries: [entry(torrentID: "T1", filename: "A.2020.mkv"),
                                       entry(torrentID: "T2", filename: "B.2021.mkv")])
        store.context.insert(WatchState(itemKey: "T1#0", positionSeconds: 10, durationSeconds: 100))
        store.context.insert(WatchState(itemKey: "T2#0", positionSeconds: 50, durationSeconds: 100))
        store.context.insert(WatchState(itemKey: "GONE#0", positionSeconds: 5, durationSeconds: 100))
        try store.context.save()
        XCTAssertEqual(try store.backfillHistory(), 2)
        XCTAssertEqual(try store.backfillHistory(), 2)
        XCTAssertEqual(try store.history().count, 2)
    }
}
