import XCTest
@testable import StreamCore

final class DownloadPathsTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/Media")

    private func dest(_ kind: String, _ title: String, _ year: Int?, _ season: Int?,
                      _ file: String) -> String {
        DownloadPaths.destination(root: root, mediaKind: kind, title: title,
                                  year: year, season: season, filename: file).path
    }

    func testMovieWithYear() {
        XCTAssertEqual(dest("movie", "Interstellar", 2014, nil, "Interstellar.2160p.mkv"),
                       "/Media/Movies/Interstellar (2014)/Interstellar.2160p.mkv")
    }

    func testMovieWithoutYear() {
        XCTAssertEqual(dest("movie", "Interstellar", nil, nil, "x.mkv"),
                       "/Media/Movies/Interstellar/x.mkv")
    }

    func testEpisode() {
        XCTAssertEqual(dest("episode", "The Bear", nil, 3, "The.Bear.S03E01.mkv"),
                       "/Media/Shows/The Bear/Season 03/The.Bear.S03E01.mkv")
    }

    func testSpecials() {
        XCTAssertEqual(dest("episode", "The Bear", nil, 0, "special.mkv"),
                       "/Media/Shows/The Bear/Specials/special.mkv")
    }

    func testEpisodeNoSeasonFallsBackToRoot() {
        XCTAssertEqual(dest("episode", "The Bear", nil, nil, "unknown.mkv"),
                       "/Media/unknown.mkv")
    }

    func testSanitizesSeparatorsInFolderNames() {
        XCTAssertEqual(dest("episode", "Face/Off: 2", nil, 1, "e.mkv"),
                       "/Media/Shows/Face-Off- 2/Season 01/e.mkv")
    }
}
