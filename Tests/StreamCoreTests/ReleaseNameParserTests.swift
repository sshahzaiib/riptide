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
            Case("Charlottes.Web.2006.1080p.BluRay.mkv",             // title contains "Web"
                 p("Charlottes Web", year: 2006, quality: "1080p", source: "BluRay")),
            Case("Charlottes.Web.1080p.mkv",                          // no year, still no WEB source
                 p("Charlottes Web", quality: "1080p")),
            Case("Blade.Runner.2049.2017.1080p.WEB-DL.mkv",           // year-like number in title
                 p("Blade Runner 2049", year: 2017, quality: "1080p", source: "WEB-DL")),
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

    func testIsExtraDetection() {
        // Real fixtures from a Breaking Bad S01 pack.
        XCTAssertTrue(ReleaseNameParser.isExtra(
            filename: "Breaking_Bad_-_S01_Extra_-_Inside_Breaking_Bad.m4v"))
        XCTAssertTrue(ReleaseNameParser.isExtra(
            filename: "Breaking_Bad_-_S01E01_Deleted_Scene_-_Walt_Jr__Helps_His_Dad.m4v"))
        XCTAssertTrue(ReleaseNameParser.isExtra(
            filename: "Breaking_Bad_-_S01_Extra_-_Making_Of_Breaking_Bad.m4v"))
        XCTAssertTrue(ReleaseNameParser.isExtra(
            filename: "Breaking_Bad_-_S01_Extra_-_Screen_Tests.m4v"))
        XCTAssertTrue(ReleaseNameParser.isExtra(
            filename: "Show.S01.Featurette.Behind.the.Scenes.mkv"))
        XCTAssertTrue(ReleaseNameParser.isExtra(
            filename: "Show.S01E04.Bloopers.mkv"))
        // Path-component detection (RD pack paths include directories).
        XCTAssertTrue(ReleaseNameParser.isExtra(
            filename: "Interview.with.the.Cast.mkv",
            path: "/Show.S01.1080p/Extras/Interview.with.the.Cast.mkv"))
        XCTAssertTrue(ReleaseNameParser.isExtra(
            filename: "clip.mkv", path: "/Show/Featurettes/clip.mkv"))

        // Must NOT match: real episodes and titles containing extras-like words.
        XCTAssertFalse(ReleaseNameParser.isExtra(
            filename: "Breaking_Bad_S01E01_Pilot_(2160p_x265_10bit_Joy).mkv"))
        XCTAssertFalse(ReleaseNameParser.isExtra(
            filename: "Extras.S01E01.720p.mkv"))          // Gervais show: leading token IS the title
        XCTAssertFalse(ReleaseNameParser.isExtra(
            filename: "Extra.Ordinary.2019.1080p.mkv"))   // leading token
        XCTAssertFalse(ReleaseNameParser.isExtra(
            filename: "Trailer.Park.Boys.S01E01.mkv"))    // "trailer park" exclusion
        XCTAssertFalse(ReleaseNameParser.isExtra(
            filename: "Extraction.2020.1080p.mkv"))       // word boundary
        XCTAssertFalse(ReleaseNameParser.isExtra(
            filename: "The.Matrix.1999.1080p.BluRay.mkv"))
        XCTAssertFalse(ReleaseNameParser.isExtra(
            filename: "clean.name.mkv", path: "/Show.S01/Season 1/clean.name.mkv"))

        // Defects test cases (TDD)
        XCTAssertFalse(ReleaseNameParser.isExtra(filename: "[SubsPlease] Extras S01E01.mkv"))
        XCTAssertFalse(ReleaseNameParser.isExtra(filename: "[Group] [1080p] Extras S01E01.mkv"))
        XCTAssertTrue(ReleaseNameParser.isExtra(filename: "[Group] Show S01 Deleted Scenes.mkv"))
        XCTAssertTrue(ReleaseNameParser.isExtra(filename: "Show.S01.Deleted..Scenes.mkv"))
        XCTAssertTrue(ReleaseNameParser.isExtra(filename: "Show.S01.Trailers.Parker.mkv"))
    }
}

