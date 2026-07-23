import XCTest
@testable import StreamCore

final class TMDBClientCacheTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        MockURLProtocol.setHandler(nil)
    }

    private func client(cache: MetadataCache?) -> TMDBClient {
        TMDBClient(bearerToken: "TOK", session: .mocked(), cache: cache)
    }

    private static let detailsJSON = """
    {"id":603,"title":"The Matrix","overview":"A hacker...",
     "poster_path":"/p.jpg","release_date":"1999-03-30","vote_average":8.2,
     "runtime":136,"genres":[]}
    """

    func testSecondCallWithinTTLSkipsTransport() async throws {
        nonisolated(unsafe) var calls = 0
        MockURLProtocol.setHandler { _ in
            calls += 1
            return .json(Self.detailsJSON)
        }
        let cache = MetadataCache(directory: dir)
        _ = try await client(cache: cache).movieDetails(id: 603)
        _ = try await client(cache: cache).movieDetails(id: 603)
        XCTAssertEqual(calls, 1)
    }

    func testExpiredEntryRefetches() async throws {
        nonisolated(unsafe) var calls = 0
        MockURLProtocol.setHandler { _ in
            calls += 1
            return .json(Self.detailsJSON)
        }
        _ = try await client(cache: MetadataCache(directory: dir))
            .movieDetails(id: 603)
        // Clock 8 days ahead: 7-day details TTL has lapsed.
        let stale = MetadataCache(
            directory: dir, now: { Date(timeIntervalSinceNow: 8 * 86_400) })
        _ = try await client(cache: stale).movieDetails(id: 603)
        XCTAssertEqual(calls, 2)
    }

    func testCorruptCachedDataRefetches() async throws {
        nonisolated(unsafe) var calls = 0
        MockURLProtocol.setHandler { _ in
            calls += 1
            return .json(Self.detailsJSON)
        }
        let cache = MetadataCache(directory: dir)
        _ = try await client(cache: cache).movieDetails(id: 603)
        await cache.store(Data("not json".utf8), for: "tmdb:movie/603?")
        _ = try await client(cache: cache).movieDetails(id: 603)
        XCTAssertEqual(calls, 2)
    }

    func testNilCacheAlwaysFetches() async throws {
        nonisolated(unsafe) var calls = 0
        MockURLProtocol.setHandler { _ in
            calls += 1
            return .json(Self.detailsJSON)
        }
        _ = try await client(cache: nil).movieDetails(id: 603)
        _ = try await client(cache: nil).movieDetails(id: 603)
        XCTAssertEqual(calls, 2)
    }
}
