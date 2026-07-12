import XCTest
@testable import StreamCore

@MainActor
final class LibraryRefresherTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.setHandler(nil)
        super.tearDown()
    }

    private func makeRefresher(store: LibraryStore) -> LibraryRefresher {
        LibraryRefresher(services: [RealDebridService(rd: RealDebridClient(token: "T", session: .mocked()))],
                         tmdb: makeTMDB(),
                         store: store)
    }

    private func makeTMDB() -> TMDBClient {
        TMDBClient(bearerToken: "K", session: .mocked())
    }

    nonisolated private static func torrentJSON(id: String, filename: String,
                                                links: [String] = ["https://rd/d/A"],
                                                status: String = "downloaded") -> String {
        let linkList = links.map { "\"\($0)\"" }.joined(separator: ",")
        return """
        {"id":"\(id)","filename":"\(filename)","hash":"h","bytes":100,"host":"rd",
         "split":2000,"progress":100,"status":"\(status)",
         "added":"2026-06-01T00:00:00.000Z","links":[\(linkList)]}
        """
    }

    func testSingleFileTorrentBecomesOneItem() async throws {
        let store = try LibraryStore.inMemory()
        MockURLProtocol.setHandler { request in
            let url = request.url!
            if url.host!.contains("real-debrid") {
                return .json("[\(Self.torrentJSON(id: "T1", filename: "The.Matrix.1999.1080p.mkv"))]")
            }
            if url.path.hasSuffix("/search/movie") {
                return .json("""
                {"results":[{"id":603,"title":"The Matrix","overview":"A hacker...",
                  "poster_path":"/p.jpg","release_date":"1999-03-30","vote_average":8.2}]}
                """)
            }
            return .json(#"{"results":[]}"#)
        }
        let summary = try await makeRefresher(store: store).refresh()
        XCTAssertEqual(summary.matched, 1)
        let item = try XCTUnwrap(try store.items().first)
        XCTAssertEqual(item.itemKey, "T1#0")
        XCTAssertEqual(item.tmdbID, 603)
    }

    func testSeasonPackExpandsPerFileAndMatchesShowOnce() async throws {
        let store = try LibraryStore.inMemory()
        nonisolated(unsafe) var tvSearchCalls = 0
        MockURLProtocol.setHandler { request in
            let url = request.url!
            if url.path.contains("/torrents/info/") {
                return .json("""
                {"id":"PACK","filename":"1080p","bytes":200,"progress":100,
                 "status":"downloaded",
                 "files":[
                   {"id":1,"path":"/Season 1/Game.of.Thrones.S01E01.1080p.mkv","bytes":90,"selected":1},
                   {"id":2,"path":"/Season 1/extras.txt","bytes":1,"selected":0},
                   {"id":3,"path":"/Season 1/Game.of.Thrones.S01E02.1080p.mkv","bytes":95,"selected":1}],
                 "links":["https://rd/d/E1","https://rd/d/E2"]}
                """)
            }
            if url.host!.contains("real-debrid") {
                return .json("[\(Self.torrentJSON(id: "PACK", filename: "1080p", links: ["https://rd/d/E1", "https://rd/d/E2"]))]")
            }
            if url.path.hasSuffix("/search/tv") {
                tvSearchCalls += 1
                return .json("""
                {"results":[{"id":1399,"name":"Game of Thrones","overview":"...",
                  "poster_path":"/got.jpg","first_air_date":"2011-04-17","vote_average":8.4}]}
                """)
            }
            return .json(#"{"results":[]}"#)
        }
        let summary = try await makeRefresher(store: store).refresh()

        // Unselected file excluded; both episodes parsed from their OWN names.
        XCTAssertEqual(summary.upsert.inserted, 2)
        XCTAssertEqual(summary.matched, 2)
        let items = try store.items().sorted { $0.fileIndex < $1.fileIndex }
        XCTAssertEqual(items.map(\.itemKey), ["PACK#0", "PACK#1"])
        XCTAssertEqual(items[0].title, "Game of Thrones")
        XCTAssertEqual(items[0].season, 1)
        XCTAssertEqual(items[0].episode, 1)
        XCTAssertEqual(items[1].episode, 2)
        XCTAssertEqual(items[0].link, "https://rd/d/E1")
        XCTAssertEqual(items[1].link, "https://rd/d/E2")
        XCTAssertEqual(items[0].tmdbID, 1399)
        XCTAssertEqual(items[1].tmdbID, 1399)
        XCTAssertEqual(tvSearchCalls, 1)     // grouped: one search for the pack
    }

    func testSecondRefreshSkipsTorrentInfo() async throws {
        let store = try LibraryStore.inMemory()
        nonisolated(unsafe) var infoCalls = 0
        MockURLProtocol.setHandler { request in
            let url = request.url!
            if url.path.contains("/torrents/info/") {
                infoCalls += 1
                return .json("""
                {"id":"PACK","filename":"1080p","bytes":200,"progress":100,
                 "status":"downloaded",
                 "files":[
                   {"id":1,"path":"/A.S01E01.mkv","bytes":90,"selected":1},
                   {"id":2,"path":"/A.S01E02.mkv","bytes":95,"selected":1}],
                 "links":["https://rd/d/E1","https://rd/d/E2"]}
                """)
            }
            if url.host!.contains("real-debrid") {
                return .json("[\(Self.torrentJSON(id: "PACK", filename: "1080p", links: ["https://rd/d/E1", "https://rd/d/E2"]))]")
            }
            return .json(#"{"results":[]}"#)
        }
        let refresher = makeRefresher(store: store)
        _ = try await refresher.refresh()
        XCTAssertEqual(infoCalls, 1)
        let second = try await refresher.refresh()
        XCTAssertEqual(infoCalls, 1)                    // cached, no second call
        XCTAssertEqual(second.upsert,
                       UpsertSummary(inserted: 0, updated: 0, deleted: 0))
        XCTAssertEqual(try store.items().count, 2)
    }

    func testNoResultsLeavesItemUnmatched() async throws {
        let store = try LibraryStore.inMemory()
        MockURLProtocol.setHandler { request in
            if request.url!.host!.contains("real-debrid") {
                return .json("[\(Self.torrentJSON(id: "T3", filename: "Obscure.Home.Video.2024.mkv"))]")
            }
            return .json(#"{"results":[]}"#)
        }
        let summary = try await makeRefresher(store: store).refresh()
        XCTAssertEqual(summary.matched, 0)
        XCTAssertEqual(summary.matchFailed, 1)
        XCTAssertNil(try XCTUnwrap(try store.items().first).tmdbID)
    }

    func testTMDBErrorIsBestEffortNotFatal() async throws {
        let store = try LibraryStore.inMemory()
        MockURLProtocol.setHandler { request in
            if request.url!.host!.contains("real-debrid") {
                return .json("[\(Self.torrentJSON(id: "T4", filename: "A.2020.mkv"))]")
            }
            return .json("{}", status: 500)
        }
        let summary = try await makeRefresher(store: store).refresh()
        XCTAssertEqual(summary.matchFailed, 1)
        XCTAssertEqual(try store.items().count, 1)
    }

    func testSkipsNonDownloadedAndLinklessTorrents() async throws {
        let store = try LibraryStore.inMemory()
        MockURLProtocol.setHandler { request in
            if request.url!.host!.contains("real-debrid") {
                return .json("""
                [\(Self.torrentJSON(id: "T6", filename: "downloading.mkv", status: "downloading")),
                 \(Self.torrentJSON(id: "T7", filename: "no-links.mkv", links: []))]
                """)
            }
            return .json(#"{"results":[]}"#)
        }
        _ = try await makeRefresher(store: store).refresh()
        XCTAssertTrue(try store.items().isEmpty)
    }

    func testTwoServicesMergeIntoOneLibrary() async throws {
        let store = try LibraryStore.inMemory()
        MockURLProtocol.setHandler { _ in .json(#"{"results":[]}"#) }   // TMDB no-match
        let rd = StubLibraryService(serviceID: .realDebrid) {
            [LibraryFileEntry(torrentID: "T1", fileIndex: 0, filename: "Movie.2020.mkv",
                              bytes: 1, added: "", link: "l1")]
        }
        let ad = StubLibraryService(serviceID: .allDebrid) {
            [LibraryFileEntry(service: "ad", torrentID: "77", fileIndex: 0,
                              filename: "Other.2021.mkv", bytes: 2, added: "", link: "l2")]
        }
        _ = try await LibraryRefresher(services: [rd, ad], tmdb: makeTMDB(), store: store).refresh()
        XCTAssertEqual(Set(try store.items().map(\.itemKey)), ["T1#0", "ad#77#0"])
    }

    func testDedupeDropsADCopyOfRDFile() async throws {
        let store = try LibraryStore.inMemory()
        MockURLProtocol.setHandler { _ in .json(#"{"results":[]}"#) }
        let rd = StubLibraryService(serviceID: .realDebrid) {
            [LibraryFileEntry(torrentID: "T1", fileIndex: 0, filename: "Movie.2020.MKV",
                              bytes: 5, added: "", link: "l1")]
        }
        let ad = StubLibraryService(serviceID: .allDebrid) {
            [LibraryFileEntry(service: "ad", torrentID: "77", fileIndex: 0,
                              filename: "movie.2020.mkv", bytes: 5, added: "", link: "l2")]
        }
        _ = try await LibraryRefresher(services: [rd, ad], tmdb: makeTMDB(), store: store).refresh()
        XCTAssertEqual(try store.items().map(\.itemKey), ["T1#0"])
    }

    func testFailingServicePreservesItsItemsAndReportsError() async throws {
        let store = try LibraryStore.inMemory()
        MockURLProtocol.setHandler { _ in .json(#"{"results":[]}"#) }
        _ = try store.upsert(entries: [LibraryFileEntry(service: "ad", torrentID: "77",
                                                        fileIndex: 0, filename: "Kept.2021.mkv",
                                                        bytes: 2, added: "", link: "l2")])
        let rd = StubLibraryService(serviceID: .realDebrid) { [] }
        let ad = StubLibraryService(serviceID: .allDebrid) { throw AllDebridError.http(500) }
        let summary = try await LibraryRefresher(services: [rd, ad],
                                                 tmdb: makeTMDB(), store: store).refresh()
        XCTAssertNotNil(summary.serviceErrors["ad"])
        XCTAssertEqual(try store.items().map(\.itemKey), ["ad#77#0"])
    }

    func testAuthFailureIsTyped() async throws {
        let store = try LibraryStore.inMemory()
        MockURLProtocol.setHandler { _ in .json(#"{"results":[]}"#) }
        let rd = StubLibraryService(serviceID: .realDebrid) { throw RealDebridError.unauthorized }
        let ad = StubLibraryService(serviceID: .allDebrid) { throw AllDebridError.authFailed }
        let summary = try await LibraryRefresher(services: [rd, ad],
                                                 tmdb: makeTMDB(), store: store).refresh()
        XCTAssertEqual(summary.authFailures, ["rd", "ad"])
    }

    func testPackExtrasAreClassifiedAndSkipMatching() async throws {
        let store = try LibraryStore.inMemory()
        nonisolated(unsafe) var tvSearchCalls = 0
        MockURLProtocol.setHandler { request in
            let url = request.url!
            if url.path.contains("/torrents/info/") {
                return .json("""
                {"id":"PACK","filename":"BB.S01","bytes":300,"progress":100,
                 "status":"downloaded",
                 "files":[
                   {"id":1,"path":"/BB.S01/Breaking.Bad.S01E01.Pilot.mkv","bytes":90,"selected":1},
                   {"id":2,"path":"/BB.S01/Breaking_Bad_-_S01E01_Deleted_Scene_-_Walt.m4v","bytes":5,"selected":1},
                   {"id":3,"path":"/BB.S01/Extras/Cast.Interview.mkv","bytes":5,"selected":1}],
                 "links":["https://rd/d/E1","https://rd/d/E2","https://rd/d/E3"]}
                """)
            }
            if url.host!.contains("real-debrid") {
                return .json("[\(Self.torrentJSON(id: "PACK", filename: "BB.S01", links: ["https://rd/d/E1", "https://rd/d/E2", "https://rd/d/E3"]))]")
            }
            if url.path.hasSuffix("/search/tv") {
                tvSearchCalls += 1
                return .json("""
                {"results":[{"id":1396,"name":"Breaking Bad","overview":"...",
                  "poster_path":"/bb.jpg","first_air_date":"2008-01-20","vote_average":8.9}]}
                """)
            }
            return .json(#"{"results":[]}"#)
        }
        let summary = try await makeRefresher(store: store).refresh()

        XCTAssertEqual(summary.matched, 1)                 // only the pilot
        XCTAssertEqual(tvSearchCalls, 1)
        let items = try store.items().sorted { $0.fileIndex < $1.fileIndex }
        XCTAssertEqual(items[0].mediaKind, "episode")
        XCTAssertEqual(items[0].tmdbID, 1396)
        XCTAssertEqual(items[1].mediaKind, "extra")        // filename token
        XCTAssertNil(items[1].tmdbID)
        XCTAssertEqual(items[2].mediaKind, "extra")        // Extras/ directory
        XCTAssertNil(items[2].tmdbID)
    }
}


private struct StubLibraryService: DebridService {
    let serviceID: DebridServiceID
    var entries: @Sendable () async throws -> [LibraryFileEntry]
    var supportsAdds: Bool { true }
    func libraryEntries(knownCounts: [String: Int],
                        cached: [String: [LibraryFileEntry]]) async throws -> [LibraryFileEntry] {
        try await entries()
    }
    func addMagnet(_ magnet: String) async throws -> DebridTransfer { fatalError("unused") }
    func transferStatus(id: String) async throws -> DebridTransfer { fatalError("unused") }
    func transferIDs() async throws -> Set<String> { [] }
    func unrestrict(link: String) async throws -> URL { fatalError("unused") }
    func delete(id: String) async throws {}
}
