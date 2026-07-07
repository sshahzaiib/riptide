import XCTest
@testable import StreamCore

final class TMDBDetailTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.setHandler(nil)
        super.tearDown()
    }

    private func client() -> TMDBClient {
        TMDBClient(bearerToken: "TOK", session: .mocked())
    }

    func testShowDetails() async throws {
        nonisolated(unsafe) var seen: URL?
        MockURLProtocol.setHandler { request in
            seen = request.url
            return .json("""
            {"id":1399,"name":"Game of Thrones","backdrop_path":"/b.jpg",
             "overview":"Seven noble families...","vote_average":8.4,
             "first_air_date":"2011-04-17"}
            """)
        }
        let details = try await client().showDetails(id: 1399)
        XCTAssertEqual(details.backdropPath, "/b.jpg")
        XCTAssertEqual(details.name, "Game of Thrones")
        XCTAssertTrue(try XCTUnwrap(seen).path.hasSuffix("/tv/1399"))
    }

    func testSeasonEpisodes() async throws {
        nonisolated(unsafe) var seen: URL?
        MockURLProtocol.setHandler { request in
            seen = request.url
            return .json("""
            {"id":3624,"episodes":[
              {"episode_number":1,"name":"Winter Is Coming","overview":"...",
               "still_path":"/s1.jpg","air_date":"2011-04-17","runtime":62},
              {"episode_number":2,"name":"The Kingsroad","overview":"...",
               "still_path":null,"air_date":"2011-04-24","runtime":null}]}
            """)
        }
        let episodes = try await client().seasonEpisodes(showID: 1399, season: 1)
        XCTAssertEqual(episodes.count, 2)
        XCTAssertEqual(episodes[0].name, "Winter Is Coming")
        XCTAssertEqual(episodes[0].runtime, 62)
        XCTAssertNil(episodes[1].stillPath)
        XCTAssertTrue(try XCTUnwrap(seen).path.hasSuffix("/tv/1399/season/1"))
    }

    func testCreditsCapAtTwelveAndRoute() async throws {
        nonisolated(unsafe) var paths: [String] = []
        let castJSON = (1...20).map {
            #"{"id":\#($0),"name":"Actor \#($0)","character":"Role \#($0)","profile_path":"/p\#($0).jpg"}"#
        }.joined(separator: ",")
        MockURLProtocol.setHandler { request in
            paths.append(request.url!.path)
            return .json(#"{"cast":[\#(castJSON)]}"#)
        }
        let show = try await client().showCredits(id: 1399)
        let movie = try await client().movieCredits(id: 603)
        XCTAssertEqual(show.count, 12)
        XCTAssertEqual(show.first?.name, "Actor 1")
        XCTAssertEqual(movie.count, 12)
        XCTAssertTrue(paths[0].hasSuffix("/tv/1399/credits"))
        XCTAssertTrue(paths[1].hasSuffix("/movie/603/credits"))
    }

    func testMovieDetails() async throws {
        MockURLProtocol.setHandler { _ in
            .json("""
            {"id":603,"title":"The Matrix","backdrop_path":"/mb.jpg",
             "overview":"A hacker...","vote_average":8.2,
             "release_date":"1999-03-30","runtime":136}
            """)
        }
        let details = try await client().movieDetails(id: 603)
        XCTAssertEqual(details.backdropPath, "/mb.jpg")
        XCTAssertEqual(details.runtime, 136)
    }
}
