import XCTest
@testable import StreamCore

final class DownloadReconcilerTests: XCTestCase {
    func testPlanClassifiesRecords() {
        let records: [(itemKey: String, state: DownloadState, localPath: String)] = [
            ("dl", .downloading, "/partial"),          // → requeue
            ("gone", .completed, "/missing.mkv"),      // → markMissing
            ("here", .completed, "/present.mkv"),      // → untouched
            ("bad", .failed, "/x"),                    // → untouched
        ]
        let plan = DownloadReconciler.plan(records: records) { path in
            path == "/present.mkv"
        }
        XCTAssertEqual(plan.requeue, ["dl"])
        XCTAssertEqual(plan.markMissing, ["gone"])
    }
}
