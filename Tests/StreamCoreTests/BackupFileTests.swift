import XCTest
@testable import StreamCore

final class BackupFileTests: XCTestCase {
    func testBackupFileRoundTrip() throws {
        let h = HistoryEntryDTO(key: "k", title: "T", year: 2020, mediaKind: "movie", tmdbID: 1, season: nil,
                                episode: nil, posterPath: nil, lastWatchedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                progress: 0.5, finished: false)
        let file = BackupFile(version: BackupFile.currentVersion, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                              keychain: ["rd-token": "abc"], defaults: Data("{}".utf8), history: [h], watchStates: [])
        let back = try BackupFile.decode(file.encoded())
        XCTAssertEqual(back.version, 1)
        XCTAssertEqual(back.keychain, ["rd-token": "abc"])
        XCTAssertEqual(back.history.count, 1)
    }

    func testBackupFileRejectsNewerVersion() throws {
        let file = BackupFile(version: 2, createdAt: Date(), keychain: [:], defaults: Data(), history: [], watchStates: [])
        XCTAssertThrowsError(try BackupFile.decode(file.encoded())) {
            guard case BackupError.unsupportedVersion(2) = $0 else { return XCTFail("\($0)") }
        }
    }

    func testCorruptDefaultsThrows() {
        let f = BackupFile(createdAt: Date(), keychain: [:], defaults: Data("[1]".utf8), history: [], watchStates: [])
        XCTAssertThrowsError(try f.defaultsDictionary()) {
            guard case BackupError.corruptDefaults = $0 else { return XCTFail("\($0)") }
        }
    }

    func testDefaultsDataDropsNonJSONValues() throws {
        let data = try BackupFile.defaultsData(from: ["a": 1, "bm": Data([1, 2])])
        let f = BackupFile(createdAt: Date(), keychain: [:], defaults: data, history: [], watchStates: [])
        XCTAssertEqual(try f.defaultsDictionary().keys.sorted(), ["a"])
    }
}
