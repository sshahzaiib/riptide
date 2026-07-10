import XCTest
@testable import StreamCore

final class TMDBAddonSupportTests: XCTestCase {
    private func client() -> TMDBClient {
        TMDBClient(bearerToken: "T", session: .mocked())
    }

    override func tearDown() {
        MockURLProtocol.setHandler(nil)
        super.tearDown()
    }

    func testExternalIDsForMovie() async throws {
        nonisolated(unsafe) var seenURL: URL?
        MockURLProtocol.setHandler { request in
            seenURL = request.url
            return .json(#"{"id":603,"imdb_id":"tt0133093"}"#)
        }
        let ids = try await client().externalIDs(movieID: 603)
        XCTAssertEqual(seenURL?.path, "/3/movie/603/external_ids")
        XCTAssertEqual(ids.imdbID, "tt0133093")
    }

    func testExternalIDsForShowWithNullIMDB() async throws {
        nonisolated(unsafe) var seenURL: URL?
        MockURLProtocol.setHandler { request in
            seenURL = request.url
            return .json(#"{"id":1396,"imdb_id":null}"#)
        }
        let ids = try await client().externalIDs(showID: 1396)
        XCTAssertEqual(seenURL?.path, "/3/tv/1396/external_ids")
        XCTAssertNil(ids.imdbID)
    }

    func testShowDetailsDecodesNumberOfSeasons() async throws {
        MockURLProtocol.setHandler { _ in .json("""
        {"id":1396,"name":"Breaking Bad","backdrop_path":null,"overview":"x",
         "vote_average":8.9,"first_air_date":"2008-01-20","number_of_seasons":5}
        """) }
        let details = try await client().showDetails(id: 1396)
        XCTAssertEqual(details.numberOfSeasons, 5)
    }
}
