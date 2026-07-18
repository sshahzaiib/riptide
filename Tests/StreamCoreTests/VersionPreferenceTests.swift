import XCTest
@testable import StreamCore
// Disambiguates against DeveloperToolsSupport.LibraryItem, which is pulled in
// implicitly by the toolchain for test targets on this SDK and otherwise
// collides by name with StreamCore's @Model LibraryItem.
import class StreamCore.LibraryItem

@MainActor
final class VersionPreferenceTests: XCTestCase {
    /// Bare @Model instances (never inserted into a container) are fine for
    /// pure ranking tests — LibraryStore.upsert itself creates-then-reads
    /// them before insertion. If the SwiftData runtime ever traps here,
    /// fall back to LibraryStore.inMemory() + upsert + items().
    /// itemKey = "<torrentID>#0".
    private func item(_ torrentID: String, filename: String) -> LibraryItem {
        LibraryItem(entry: LibraryFileEntry(torrentID: torrentID, fileIndex: 0,
                                            filename: filename, bytes: 0,
                                            added: "", link: "L"),
                    parsed: ReleaseNameParser.parse(filename))
    }

    private func state(_ itemKey: String, at: Date) -> (String, WatchState) {
        (itemKey, WatchState(itemKey: itemKey, positionSeconds: 10,
                             durationSeconds: 100, lastWatchedAt: at))
    }

    func testLastPlayedBeatsQuality() {
        let sd = item("T1", filename: "Show.S01E01.720p.mkv")
        let uhd = item("T2", filename: "Show.S01E01.2160p.mkv")
        let states = Dictionary(uniqueKeysWithValues:
            [state("T1#0", at: Date(timeIntervalSince1970: 1_000_000))])
        XCTAssertEqual(VersionPreference.ranked(items: [uhd, sd], states: states)
            .map(\.itemKey), ["T1#0", "T2#0"])
        XCTAssertEqual(VersionPreference.preferred(items: [uhd, sd], states: states)?.itemKey,
                       "T1#0")
    }

    func testQualityRankingWithoutHistory() {
        let items = [item("A", filename: "M.2020.480p.mkv"),
                     item("B", filename: "M.2020.1080p.mkv"),
                     item("C", filename: "M.2020.2160p.mkv"),
                     item("D", filename: "M.2020.720p.mkv")]
        XCTAssertEqual(VersionPreference.ranked(items: items, states: [:]).map(\.torrentID),
                       ["C", "B", "D", "A"])
    }

    func testMissingAndGarbageQualityRankLast() {
        let known = item("A", filename: "M.2020.480p.mkv")
        let unknown = item("B", filename: "M.2020.mkv")          // quality nil
        XCTAssertEqual(VersionPreference.ranked(items: [unknown, known], states: [:])
            .map(\.torrentID), ["A", "B"])
    }

    func testStableOrderOnFullTie() {
        let first = item("A", filename: "M.2020.1080p.x264.mkv")
        let second = item("B", filename: "M.2020.1080p.x265.mkv")
        XCTAssertEqual(VersionPreference.ranked(items: [first, second], states: [:])
            .map(\.torrentID), ["A", "B"])
    }

    func testSubSecondTimestampDifferenceIsATie() {
        // setWatched stamps duplicates microseconds apart — quality must
        // decide, not write order.
        let base = Date(timeIntervalSince1970: 1_000_000)
        let sd = item("T1", filename: "Show.S01E01.720p.mkv")
        let uhd = item("T2", filename: "Show.S01E01.2160p.mkv")
        let states = Dictionary(uniqueKeysWithValues: [
            state("T1#0", at: base.addingTimeInterval(0.4)),
            state("T2#0", at: base),
        ])
        XCTAssertEqual(VersionPreference.preferred(items: [sd, uhd], states: states)?.itemKey,
                       "T2#0")
    }

    func testEmptyItemsGiveNilPreferred() {
        XCTAssertNil(VersionPreference.preferred(items: [], states: [:]))
    }
}
