import XCTest
@testable import StreamCore

final class ShelfCodableTests: XCTestCase {
    func testShelfSnapshotTypesRoundTrip() throws {
        let movie = TMDBMovie(id: 603, title: "The Matrix", overview: "o",
                              posterPath: "/p.jpg", releaseDate: "1999-03-31", voteAverage: 8.2)
        let show = TMDBShow(id: 1396, name: "Breaking Bad", overview: "o",
                            posterPath: nil, firstAirDate: "2008-01-20", voteAverage: 8.9)
        let item = UpNextItem(isShow: true, tmdbID: 1396, season: 2, number: 3,
                              episodeTitle: "Bit by a Dead Bee", progressPercent: 42.5,
                              sortDate: Date(timeIntervalSince1970: 1_700_000_000))
        let enc = JSONEncoder(), dec = JSONDecoder()
        XCTAssertEqual(try dec.decode(TMDBMovie.self, from: enc.encode(movie)), movie)
        XCTAssertEqual(try dec.decode(TMDBShow.self, from: enc.encode(show)), show)
        XCTAssertEqual(try dec.decode(UpNextItem.self, from: enc.encode(item)), item)
    }
}
