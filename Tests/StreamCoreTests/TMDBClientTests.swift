import XCTest
@testable import StreamCore

final class TMDBClientTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.setHandler(nil)
        super.tearDown()
    }

    private func client() -> TMDBClient {
        TMDBClient(bearerToken: "TOK", session: .mocked())
    }

    func testSearchMovieRequestAndDecode() async throws {
        nonisolated(unsafe) var seen: URLRequest?
        MockURLProtocol.setHandler { request in
            seen = request
            return .json("""
            {"page":1,"results":[{"id":603,"title":"The Matrix",
              "overview":"A hacker...","poster_path":"/p.jpg",
              "release_date":"1999-03-30","vote_average":8.2}]}
            """)
        }
        let results = try await client().searchMovie(title: "The Matrix", year: 1999)
        XCTAssertEqual(results, [TMDBMovie(id: 603, title: "The Matrix",
                                           overview: "A hacker...", posterPath: "/p.jpg",
                                           releaseDate: "1999-03-30", voteAverage: 8.2)])
        let req = try XCTUnwrap(seen)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer TOK")
        let comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
        XCTAssertTrue(comps.path.hasSuffix("/search/movie"))
        XCTAssertEqual(Set(comps.queryItems ?? []),
                       [URLQueryItem(name: "primary_release_year", value: "1999"),
                        URLQueryItem(name: "query", value: "The Matrix")])
    }

    func testSearchTVOmitsYearWhenNil() async throws {
        nonisolated(unsafe) var seen: URL?
        MockURLProtocol.setHandler { request in
            seen = request.url
            return .json("""
            {"page":1,"results":[{"id":1396,"name":"Breaking Bad","overview":"...",
              "poster_path":null,"first_air_date":"2008-01-20","vote_average":8.9}]}
            """)
        }
        let results = try await client().searchTV(title: "Breaking Bad", year: nil)
        XCTAssertEqual(results.first?.id, 1396)
        XCTAssertNil(results.first?.posterPath)
        let comps = URLComponents(url: try XCTUnwrap(seen), resolvingAgainstBaseURL: false)!
        XCTAssertTrue(comps.path.hasSuffix("/search/tv"))
        XCTAssertEqual(comps.queryItems, [URLQueryItem(name: "query", value: "Breaking Bad")])
    }

    func testEpisodeFetch() async throws {
        nonisolated(unsafe) var seen: URL?
        MockURLProtocol.setHandler { request in
            seen = request.url
            return .json("""
            {"id":62161,"name":"Ozymandias","overview":"...",
             "still_path":"/s.jpg","air_date":"2013-09-15"}
            """)
        }
        let ep = try await client().episode(showID: 1396, season: 5, episode: 14)
        XCTAssertEqual(ep.name, "Ozymandias")
        XCTAssertTrue(try XCTUnwrap(seen).path.hasSuffix("/tv/1396/season/5/episode/14"))
    }

    func testUnauthorizedMapsToError() async {
        MockURLProtocol.setHandler { _ in .json(#"{"status_code":7}"#, status: 401) }
        do {
            _ = try await client().searchMovie(title: "x", year: nil)
            XCTFail("expected throw")
        } catch let e as TMDBError {
            XCTAssertEqual(e, .unauthorized)
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testImageURL() {
        XCTAssertEqual(TMDB.imageURL(path: "/p.jpg").absoluteString,
                       "https://image.tmdb.org/t/p/w500/p.jpg")
    }
}
