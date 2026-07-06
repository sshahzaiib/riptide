import XCTest
@testable import StreamCore

final class ReleaseNameParserTests: XCTestCase {
    private struct Case {
        let input: String
        let expected: ParsedRelease
        let line: UInt
        init(_ input: String, _ expected: ParsedRelease, line: UInt = #line) {
            self.input = input; self.expected = expected; self.line = line
        }
    }

    private func p(_ title: String, year: Int? = nil, season: Int? = nil,
                   episode: Int? = nil, quality: String? = nil,
                   source: String? = nil) -> ParsedRelease {
        ParsedRelease(title: title, year: year, season: season,
                      episode: episode, quality: quality, source: source)
    }

    func testFixtureTable() {
        let cases: [Case] = [
            Case("The.Matrix.1999.1080p.BluRay.x264-GROUP.mkv",
                 p("The Matrix", year: 1999, quality: "1080p", source: "BluRay")),
            Case("Dune.Part.Two.2024.2160p.WEB-DL.DDP5.1.Atmos.mkv",
                 p("Dune Part Two", year: 2024, quality: "2160p", source: "WEB-DL")),
            Case("Breaking.Bad.S05E14.720p.HDTV.x264-ASAP.mkv",
                 p("Breaking Bad", season: 5, episode: 14, quality: "720p", source: "HDTV")),
            Case("The.Bear.2022.S03E01.1080p.WEB.h264-SUCCESSFULCRAB.mkv",
                 p("The Bear", year: 2022, season: 3, episode: 1, quality: "1080p", source: "WEB")),
            Case("show name 1x02 whatever.mp4",
                 p("show name", season: 1, episode: 2)),
            Case("2012.2009.1080p.BluRay.mkv",                       // leading-year title
                 p("2012", year: 2009, quality: "1080p", source: "BluRay")),
            Case("Movie.Without.Year.1080p.mkv",
                 p("Movie Without Year", quality: "1080p")),
            Case("Oppenheimer (2023) 2160p WEBRip.mp4",              // parenthesised year
                 p("Oppenheimer", year: 2023, quality: "2160p", source: "WEBRip")),
            Case("[SubsPlease] Frieren - 05 [1080p].mkv",            // anime style
                 p("Frieren", episode: 5, quality: "1080p")),
            Case("The.Office.US.S09E23.S09E24.720p.WEB-DL.mkv",      // double episode: first wins
                 p("The Office US", season: 9, episode: 23, quality: "720p", source: "WEB-DL")),
            Case("Interstellar.2014.IMAX.2160p.4K.BluRay.mkv",
                 p("Interstellar", year: 2014, quality: "2160p", source: "BluRay")),
            Case("Some.Movie.4K.HDR.mkv",                            // 4K token maps to 2160p
                 p("Some Movie", quality: "2160p")),
            Case("plain_filename.mkv", p("plain filename")),
            Case("no extension at all", p("no extension at all")),
            Case("Snowpiercer.1x09.HDTV.mp4",
                 p("Snowpiercer", season: 1, episode: 9, source: "HDTV")),
        ]
        for c in cases {
            let got = ReleaseNameParser.parse(c.input)
            XCTAssertEqual(got, c.expected, "input: \(c.input)", line: c.line)
        }
    }

    func testIsTV() {
        XCTAssertTrue(ReleaseNameParser.parse("A.S01E01.mkv").isTV)
        XCTAssertTrue(ReleaseNameParser.parse("[G] B - 03 [720p].mkv").isTV)
        XCTAssertFalse(ReleaseNameParser.parse("A.2020.1080p.mkv").isTV)
    }
}
