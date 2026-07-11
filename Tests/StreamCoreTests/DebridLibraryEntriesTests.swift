import XCTest
@testable import StreamCore

final class DebridLibraryEntriesTests: XCTestCase {
    var session: URLSession!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() { MockURLProtocol.setHandler(nil); super.tearDown() }

    // MARK: Real-Debrid adapter

    private func rdService() -> RealDebridService {
        RealDebridService(rd: RealDebridClient(token: "t", session: session, sleep: { _ in }))
    }

    func testRDSingleFileTorrentFlattens() async throws {
        MockURLProtocol.setHandler { _ in .json("""
            [{"id":"T1","filename":"Movie.mkv","hash":"h","bytes":9,"host":"rd",
              "split":1,"progress":100,"status":"downloaded",
              "added":"2026-06-01T00:00:00.000Z","links":["https://rd/d/A"]}]
            """) }
        let entries = try await rdService().libraryEntries(knownCounts: [:], cached: [:])
        XCTAssertEqual(entries, [LibraryFileEntry(torrentID: "T1", fileIndex: 0,
                                                  filename: "Movie.mkv", bytes: 9,
                                                  added: "2026-06-01T00:00:00.000Z",
                                                  link: "https://rd/d/A")])
    }

    func testRDKnownPackSkipsTorrentInfo() async throws {
        nonisolated(unsafe) var infoCalls = 0
        let cachedEntry = LibraryFileEntry(torrentID: "PACK", fileIndex: 0,
                                           filename: "E1.mkv", bytes: 5,
                                           added: "", link: "https://rd/d/E1")
        MockURLProtocol.setHandler { request in
            if request.url!.path.contains("/torrents/info/") { infoCalls += 1 }
            return .json("""
            [{"id":"PACK","filename":"pack","hash":"h","bytes":9,"host":"rd",
              "split":1,"progress":100,"status":"downloaded",
              "added":"2026-06-01T00:00:00.000Z",
              "links":["https://rd/d/E1","https://rd/d/E2"]}]
            """)
        }
        let entries = try await rdService().libraryEntries(
            knownCounts: ["PACK": 2], cached: ["PACK": [cachedEntry]])
        XCTAssertEqual(entries, [cachedEntry])
        XCTAssertEqual(infoCalls, 0)
    }

    // MARK: AllDebrid adapter

    private func adService() -> AllDebridService {
        AllDebridService(client: AllDebridClient(token: "t", session: session, sleep: { _ in }))
    }

    func testADReadyMagnetFlattensVideosOnly() async throws {
        MockURLProtocol.setHandler { request in
            if request.url!.path.contains("magnet/files") {
                return .json("""
                {"status":"success","data":{"magnets":[{"id":77,"files":[
                  {"n":"Show.S01E01.mkv","s":100,"l":"https://ad/f/1"},
                  {"n":"junk.txt","s":1,"l":"https://ad/f/2"}]}]}}
                """)
            }
            return .json("""
            {"status":"success","data":{"magnets":[
              {"id":77,"filename":"Show","size":100,"status":"Ready",
               "statusCode":4,"downloaded":100,"uploadDate":1750000000},
              {"id":78,"filename":"Pending","size":10,"status":"Downloading",
               "statusCode":1,"downloaded":5}]}}
            """)
        }
        let entries = try await adService().libraryEntries(knownCounts: [:], cached: [:])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].service, "ad")
        XCTAssertEqual(entries[0].itemKey, "ad#77#0")
        XCTAssertEqual(entries[0].link, "https://ad/f/1")
        XCTAssertEqual(entries[0].added,
                       Date(timeIntervalSince1970: 1_750_000_000).ISO8601Format())
    }

    func testADKnownMagnetSkipsFilesCall() async throws {
        nonisolated(unsafe) var filesCalls = 0
        let cachedEntry = LibraryFileEntry(service: "ad", torrentID: "77", fileIndex: 0,
                                           filename: "Show.S01E01.mkv", bytes: 100,
                                           added: "", link: "https://ad/f/1")
        MockURLProtocol.setHandler { request in
            if request.url!.path.contains("magnet/files") { filesCalls += 1 }
            return .json("""
            {"status":"success","data":{"magnets":[
              {"id":77,"filename":"Show","size":100,"status":"Ready",
               "statusCode":4,"downloaded":100}]}}
            """)
        }
        let entries = try await adService().libraryEntries(
            knownCounts: [:], cached: ["77": [cachedEntry]])
        XCTAssertEqual(entries, [cachedEntry])
        XCTAssertEqual(filesCalls, 0)
    }
}
