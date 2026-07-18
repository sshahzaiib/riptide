import XCTest
import SwiftData
@testable import StreamCore

@MainActor
final class DownloadRecordStoreTests: XCTestCase {
    func testUpsertInsertsThenUpdates() throws {
        let store = try LibraryStore.inMemory()
        try store.upsertDownload(itemKey: "T1#0", localPath: "/tmp/a.mkv",
            state: .downloading, totalBytes: 0, downloadedBytes: 0,
            title: "A", filename: "a.mkv")
        XCTAssertEqual(try store.downloadRecord(itemKey: "T1#0")?.state, .downloading)

        try store.upsertDownload(itemKey: "T1#0", localPath: "/tmp/a.mkv",
            state: .completed, totalBytes: 100, downloadedBytes: 100,
            title: "A", filename: "a.mkv")
        let rec = try XCTUnwrap(store.downloadRecord(itemKey: "T1#0"))
        XCTAssertEqual(rec.state, .completed)
        XCTAssertEqual(rec.downloadedBytes, 100)
        XCTAssertEqual(try store.allDownloads().count, 1)   // upsert, not duplicate
    }

    func testCompletedDownloadsFilterAndDelete() throws {
        let store = try LibraryStore.inMemory()
        try store.upsertDownload(itemKey: "A", localPath: "/x", state: .completed,
            totalBytes: 1, downloadedBytes: 1, title: "A", filename: "a")
        try store.upsertDownload(itemKey: "B", localPath: "/y", state: .downloading,
            totalBytes: 0, downloadedBytes: 0, title: "B", filename: "b")
        XCTAssertEqual(try store.completedDownloads().map(\.itemKey), ["A"])

        try store.deleteDownload(itemKey: "A")
        XCTAssertNil(try store.downloadRecord(itemKey: "A"))
    }
}
