import XCTest
@testable import StreamCore

final class StremioAddonClientTests: XCTestCase {
    private func client() -> StremioAddonClient {
        StremioAddonClient(session: .mocked())
    }

    override func tearDown() {
        MockURLProtocol.setHandler(nil)
        super.tearDown()
    }

    // MARK: - normalizedBase

    func testNormalizedBaseStripsManifestSuffixAndSlashes() {
        let raw = "https://torrentio.strem.fun/realdebrid=KEY123/manifest.json"
        XCTAssertEqual(StremioAddonClient.normalizedBase(from: raw)?.absoluteString,
                       "https://torrentio.strem.fun/realdebrid=KEY123")
        XCTAssertEqual(StremioAddonClient.normalizedBase(from: "https://host/base/")?.absoluteString,
                       "https://host/base")
        XCTAssertEqual(StremioAddonClient.normalizedBase(from: "  https://host/base  ")?.absoluteString,
                       "https://host/base")
    }

    func testNormalizedBaseRejectsGarbage() {
        XCTAssertNil(StremioAddonClient.normalizedBase(from: "not a url"))
        XCTAssertNil(StremioAddonClient.normalizedBase(from: "ftp://host/base"))
        XCTAssertNil(StremioAddonClient.normalizedBase(from: ""))
    }

    // MARK: - manifest

    func testManifestDecodesStringAndObjectResources() async throws {
        MockURLProtocol.setHandler { _ in .json("""
        {"id":"com.stremio.torrentio.addon","version":"0.0.15","name":"Torrentio RD",
         "resources":["catalog",{"name":"stream","types":["movie","series"]}],
         "types":["movie","series"]}
        """) }
        let manifest = try await client().manifest(baseURL: URL(string: "https://host/base")!)
        XCTAssertEqual(manifest.name, "Torrentio RD")
        XCTAssertTrue(manifest.supportsStreams)
    }

    func testManifestWithoutStreamResource() async throws {
        MockURLProtocol.setHandler { _ in .json("""
        {"id":"x","version":"1.0.0","name":"Catalog Only","resources":["catalog"],"types":["movie"]}
        """) }
        let manifest = try await client().manifest(baseURL: URL(string: "https://host/base")!)
        XCTAssertFalse(manifest.supportsStreams)
    }

    // MARK: - streams

    func testStreamsBuildsSeriesPathAndDecodesTorrentioShape() async throws {
        nonisolated(unsafe) var seenURL: URL?
        MockURLProtocol.setHandler { request in
            seenURL = request.url
            return .json("""
            {"streams":[
              {"name":"[RD+] Torrentio\\n1080p",
               "title":"Show.S01E02.1080p.WEB-DL\\n👤 89 💾 4.29 GB ⚙️ RARBG",
               "url":"https://torrentio.strem.fun/realdebrid/KEY/HASH/null/0/file.mkv",
               "behaviorHints":{"bingeGroup":"torrentio|1080p","filename":"file.mkv"}},
              {"name":"Torrentio\\n720p",
               "title":"Show.S01E02.720p",
               "infoHash":"abc123def",
               "fileIdx":0}
            ]}
            """)
        }
        let streams = try await client().streams(baseURL: URL(string: "https://host/base")!,
                                                 type: .series, imdbID: "tt0944947",
                                                 season: 1, episode: 2)
        XCTAssertEqual(seenURL?.absoluteString, "https://host/base/stream/series/tt0944947:1:2.json")
        XCTAssertEqual(streams.count, 2)
        XCTAssertNotNil(streams[0].httpURL)
        XCTAssertEqual(streams[0].behaviorHints?.filename, "file.mkv")
        XCTAssertNil(streams[1].httpURL)          // infoHash-only → no playable URL
        XCTAssertEqual(streams[1].infoHash, "abc123def")
    }

    func testStreamsMoviePathAndAIOStreamsShape() async throws {
        nonisolated(unsafe) var seenURL: URL?
        MockURLProtocol.setHandler { request in
            seenURL = request.url
            return .json("""
            {"streams":[
              {"name":"⚡ AIOStreams 1080p",
               "description":"Movie 2023 1080p BluRay\\n📦 8.5 GB",
               "url":"https://aiostreams.example/playback/token/file.mkv",
               "behaviorHints":{"videoSize":9126805504,"filename":"Movie.2023.mkv"}}
            ]}
            """)
        }
        let streams = try await client().streams(baseURL: URL(string: "https://host/base")!,
                                                 type: .movie, imdbID: "tt0111161")
        XCTAssertEqual(seenURL?.absoluteString, "https://host/base/stream/movie/tt0111161.json")
        XCTAssertEqual(streams[0].behaviorHints?.videoSize, 9_126_805_504)
        XCTAssertNil(streams[0].title)
        XCTAssertEqual(streams[0].description, "Movie 2023 1080p BluRay\n📦 8.5 GB")
    }

    /// Some addons emit stream URLs with unencoded spaces; those must still
    /// yield a playable URL instead of being silently dropped.
    func testHTTPURLPercentEncodesUnencodedSpaces() throws {
        let json = #"{"name":"T","url":"https://resolver.example/My Movie (2023).mkv"}"#
        let stream = try JSONDecoder().decode(AddonStream.self, from: Data(json.utf8))
        let url = try XCTUnwrap(stream.httpURL)
        XCTAssertEqual(url.absoluteString,
                       "https://resolver.example/My%20Movie%20(2023).mkv")
    }

    /// Already-encoded URLs must not be double-encoded.
    func testHTTPURLLeavesEncodedURLsAlone() throws {
        let json = #"{"name":"T","url":"https://resolver.example/My%20Movie.mkv"}"#
        let stream = try JSONDecoder().decode(AddonStream.self, from: Data(json.utf8))
        XCTAssertEqual(try XCTUnwrap(stream.httpURL).absoluteString,
                       "https://resolver.example/My%20Movie.mkv")
    }

    func testErrorMapping() async {
        MockURLProtocol.setHandler { _ in .json("oops", status: 500) }
        do {
            _ = try await client().manifest(baseURL: URL(string: "https://host/base")!)
            XCTFail("expected badStatus")
        } catch let error as StremioAddonError {
            XCTAssertEqual(error, .badStatus(500))
        } catch { XCTFail("wrong error: \(error)") }

        MockURLProtocol.setHandler { _ in .json("not json at all") }
        do {
            _ = try await client().streams(baseURL: URL(string: "https://host/base")!,
                                           type: .movie, imdbID: "tt1")
            XCTFail("expected badResponse")
        } catch let error as StremioAddonError {
            XCTAssertEqual(error, .badResponse)
        } catch { XCTFail("wrong error: \(error)") }
    }
}
