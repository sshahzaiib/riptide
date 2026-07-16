import XCTest
@testable import StreamCore

final class ChapterMarkersTests: XCTestCase {
    // Real dump from Game of Thrones S3E6 (53:22) — the file from the bug
    // report. 8 chapters, no names: mpv returned "00:01:54.114" etc. as the
    // titles, which is what makes shape-based detection necessary.
    private let gotStarts: [Double] = [0, 114.11, 495.20, 893.39,
                                       1328.16, 1885.47, 2406.90, 3122.33]
    private let gotDuration = 3202.0

    func testRealFileDetectsTitlesAndCredits() {
        let m = ChapterMarkers.detect(chapterStarts: gotStarts, duration: gotDuration)
        // ch0 is 114s (GoT's titles run ~1:50) and the only candidate:
        // ch1 is 381s, and the 80s credits chapter starts at 52:02 — far
        // outside the 6-minute search window.
        XCTAssertEqual(m.intro, 0..<114.11)
        XCTAssertEqual(m.creditsStart, 3122.33)
    }

    func testColdOpenPicksTitlesNotColdOpen() {
        // ch0 = 150s cold open, ch1 = 110s titles. Shortest wins, so the
        // titles are chosen even though the cold open comes first.
        let m = ChapterMarkers.detect(chapterStarts: [0, 150, 260, 900, 1800],
                                      duration: 2400)
        XCTAssertEqual(m.intro, 150..<260)
    }

    func testShortEpisodeDetectsCredits() {
        // 24-minute episode: credits chapter starts at 22:30. This is the
        // case that would advance at 94.4% and linger in Continue Watching
        // without the finishing flag (Task 3).
        let m = ChapterMarkers.detect(chapterStarts: [0, 90, 200, 700, 1350],
                                      duration: 1440)
        XCTAssertEqual(m.intro, 0..<90)
        XCTAssertEqual(m.creditsStart, 1350)
    }

    func testLongFinalActIsNotCredits() {
        // Final chapter is a 12-minute act, not credits — must not trigger
        // Up Next twelve minutes early.
        let m = ChapterMarkers.detect(chapterStarts: [0, 114, 600, 1200],
                                      duration: 1920)
        XCTAssertEqual(m.intro, 0..<114)
        XCTAssertNil(m.creditsStart)
    }

    func testNoChaptersIsNone() {
        XCTAssertEqual(ChapterMarkers.detect(chapterStarts: [], duration: 3202),
                       ChapterMarkers.none)
    }

    func testAllLongChaptersIsNone() {
        XCTAssertEqual(ChapterMarkers.detect(chapterStarts: [0, 600, 1200],
                                             duration: 1800),
                       ChapterMarkers.none)
    }

    func testSingleChapterIsNone() {
        XCTAssertEqual(ChapterMarkers.detect(chapterStarts: [0], duration: 3202),
                       ChapterMarkers.none)
    }

    func testZeroDurationIsNone() {
        XCTAssertEqual(ChapterMarkers.detect(chapterStarts: gotStarts, duration: 0),
                       ChapterMarkers.none)
    }

    func testIntroSpanIsNeverAlsoCredits() {
        // Degenerate 2-chapter file: the shortest early span is also the last
        // span. It must not be reported as both the intro and the credits.
        let m = ChapterMarkers.detect(chapterStarts: [0, 114], duration: 200)
        XCTAssertEqual(m.intro, 114..<200)
        XCTAssertNil(m.creditsStart)
    }
}
