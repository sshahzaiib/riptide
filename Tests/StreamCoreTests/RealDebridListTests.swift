import XCTest
@testable import StreamCore

final class RealDebridListTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.setHandler(nil)
        super.tearDown()
    }

    private func client() -> RealDebridClient {
        RealDebridClient(token: "T", session: .mocked())
    }

    private static let torrentJSON = """
    [{"id":"ABCDEF","filename":"The.Matrix.1999.1080p.BluRay.x264.mkv","hash":"h1",
      "bytes":8589934592,"host":"real-debrid.com","split":2000,"progress":100,
      "status":"downloaded","added":"2026-06-01T10:00:00.000Z",
      "links":["https://real-debrid.com/d/AAA"],"ended":"2026-06-01T10:05:00.000Z"},
     {"id":"GHIJKL","filename":"pack","hash":"h2","bytes":0,"host":"real-debrid.com",
      "split":2000,"progress":40,"status":"downloading","added":"2026-06-02T10:00:00.000Z",
      "links":[]}]
    """

    func testListTorrentsDecodesAndSendsPagination() async throws {
        nonisolated(unsafe) var seenURL: URL?
        MockURLProtocol.setHandler { request in
            seenURL = request.url
            return .json(Self.torrentJSON)
        }
        let items = try await client().listTorrents(page: 3, limit: 50)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].id, "ABCDEF")
        XCTAssertEqual(items[0].filename, "The.Matrix.1999.1080p.BluRay.x264.mkv")
        XCTAssertEqual(items[0].bytes, 8_589_934_592)
        XCTAssertEqual(items[0].links, ["https://real-debrid.com/d/AAA"])
        XCTAssertEqual(items[0].ended, "2026-06-01T10:05:00.000Z")
        XCTAssertNil(items[1].ended)          // omitted for in-progress torrents
        let comps = URLComponents(url: try XCTUnwrap(seenURL), resolvingAgainstBaseURL: false)!
        XCTAssertTrue(comps.path.hasSuffix("/torrents"))
        XCTAssertEqual(Set(comps.queryItems ?? []),
                       [URLQueryItem(name: "limit", value: "50"),
                        URLQueryItem(name: "page", value: "3")])
    }

    func testListDownloadsDecodes() async throws {
        MockURLProtocol.setHandler { _ in
            .json("""
            [{"id":"DL1","filename":"movie.mkv","mimeType":"video/x-matroska",
              "filesize":1000,"link":"https://real-debrid.com/d/AAA",
              "host":"real-debrid.com","chunks":32,
              "download":"https://cdn.real-debrid.com/dl/movie.mkv","streamable":1,
              "generated":"2026-06-03T00:00:00.000Z"}]
            """)
        }
        let items = try await client().listDownloads()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].download, "https://cdn.real-debrid.com/dl/movie.mkv")
        XCTAssertEqual(items[0].streamable, 1)
        XCTAssertEqual(items[0].mimeType, "video/x-matroska")
    }

    func testAllTorrentsPagesUntilShortPage() async throws {
        // page 1 returns `limit` items (full page), page 2 returns 1 (short page) -> stop.
        nonisolated(unsafe) var pagesRequested: [String] = []
        MockURLProtocol.setHandler { request in
            let comps = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            let page = comps.queryItems!.first { $0.name == "page" }!.value!
            pagesRequested.append(page)
            func item(_ id: String) -> String {
                """
                {"id":"\(id)","filename":"f","hash":"h","bytes":1,"host":"rd",
                 "split":2000,"progress":100,"status":"downloaded",
                 "added":"2026-06-01T00:00:00.000Z","links":[]}
                """
            }
            if page == "1" { return .json("[\(item("A")),\(item("B"))]") }
            return .json("[\(item("C"))]")
        }
        let all = try await client().allTorrents(limit: 2)
        XCTAssertEqual(all.map(\.id), ["A", "B", "C"])
        XCTAssertEqual(pagesRequested, ["1", "2"])
    }

    func testEmptyLibraryReturnsEmptyArray() async throws {
        // RD returns 204 No Content with empty body for an empty list.
        MockURLProtocol.setHandler { _ in .json("", status: 204) }
        let items = try await client().listTorrents()
        XCTAssertEqual(items, [])
    }
}
