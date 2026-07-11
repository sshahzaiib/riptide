import XCTest
@testable import StreamCore

final class TorrentAdderTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.setHandler(nil)
        super.tearDown()
    }

    private func client() -> RealDebridClient {
        RealDebridClient(token: "tok", session: .mocked(),
                         config: .init(pollInterval: 0.001, pollTimeout: 1),
                         sleep: { _ in })
    }

    // MARK: Endpoints

    func testAddTorrentFilePUTsRawBody() async throws {
        nonisolated(unsafe) var captured: (method: String?, contentType: String?,
                                           body: Data?, path: String?)
        MockURLProtocol.setHandler { req in
            captured = (req.httpMethod, req.value(forHTTPHeaderField: "Content-Type"),
                        req.bodyData, req.url?.path)
            return .json(#"{"id":"TID","uri":"https://real-debrid.com/torrents/TID"}"#,
                         status: 201)
        }
        let bytes = Data([0x64, 0x38, 0x3a])   // "d8:" bencode prefix
        let result = try await client().addTorrentFile(bytes)
        XCTAssertEqual(result.id, "TID")
        XCTAssertEqual(captured.method, "PUT")
        XCTAssertEqual(captured.contentType, "application/x-bittorrent")
        XCTAssertEqual(captured.body, bytes)
        XCTAssertEqual(captured.path, "/rest/1.0/torrents/addTorrent")
    }

    func testDeleteTorrentSendsDELETE() async throws {
        nonisolated(unsafe) var captured: (method: String?, path: String?)
        MockURLProtocol.setHandler { req in
            captured = (req.httpMethod, req.url?.path)
            return .init(status: 204)
        }
        try await client().deleteTorrent("TID")
        XCTAssertEqual(captured.method, "DELETE")
        XCTAssertEqual(captured.path, "/rest/1.0/torrents/delete/TID")
    }

    func testTorrentListItemDecodesHash() throws {
        let json = #"{"id":"T1","filename":"x.mkv","hash":"ABCDEF0123","bytes":1,"progress":100,"status":"downloaded","added":"2026-01-01T00:00:00.000Z","links":[]}"#
        let item = try JSONDecoder().decode(TorrentListItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.hash, "ABCDEF0123")
    }

    // MARK: TorrentAdder

    /// Scripted RD backend: magnet/file add → waiting_files_selection with
    /// `files`, selection captured, post-select status configurable.
    private func scriptedHandler(files: String, postSelectStatus: String,
                                 existingTorrents: String = "[]",
                                 record: @escaping @Sendable (String, String?) -> Void)
        -> (@Sendable (URLRequest) -> MockURLProtocol.Stub) {
        nonisolated(unsafe) var selected = false
        return { req in
            let path = req.url!.path
            record(path, req.bodyData.flatMap { String(data: $0, encoding: .utf8) })
            switch true {
            case path.hasSuffix("/torrents") && req.httpMethod == "GET":
                return .json(existingTorrents)
            case path.hasSuffix("/torrents/addMagnet"),
                 path.hasSuffix("/torrents/addTorrent"):
                return .json(#"{"id":"TID","uri":"u"}"#, status: 201)
            case path.contains("/torrents/selectFiles/"):
                selected = true
                return .init(status: 204)
            case path.contains("/torrents/delete/"):
                return .init(status: 204)
            case path.contains("/torrents/info/"):
                let status = selected ? postSelectStatus : "waiting_files_selection"
                return .json(#"{"id":"TID","filename":"pack","bytes":9,"progress":0,"status":"\#(status)","files":\#(files),"links":[]}"#)
            default:
                return .init(status: 404)
            }
        }
    }

    private let mixedPack = #"""
    [{"id":1,"path":"/pack/S01E01.mkv","bytes":900,"selected":0},
     {"id":2,"path":"/pack/Sample/sample.mkv","bytes":10,"selected":0},
     {"id":3,"path":"/pack/info.nfo","bytes":1,"selected":0},
     {"id":4,"path":"/pack/S01E02.mp4","bytes":900,"selected":0}]
    """#

    func testAddSelectsOnlyVideoFiles() async throws {
        nonisolated(unsafe) var selectBody: String?
        MockURLProtocol.setHandler(scriptedHandler(files: mixedPack,
                                                   postSelectStatus: "downloaded") { path, body in
            if path.contains("/selectFiles/") { selectBody = body }
        })
        let added = try await TorrentAdder(rd: client())
            .add(.magnet("magnet:?xt=urn:btih:cafebabe&dn=pack"))
        XCTAssertEqual(selectBody, "files=1%2C4")   // formEncode percent-encodes the comma
        XCTAssertEqual(added.outcome, .ready(torrentID: "TID"))
        XCTAssertEqual(added.selectedFileIDs, [1, 4])
        XCTAssertEqual(added.files.count, 4)
    }

    func testAddAllJunkFallsBackToSelectAll() async throws {
        nonisolated(unsafe) var selectBody: String?
        let junk = #"[{"id":1,"path":"/a.nfo","bytes":1,"selected":0},{"id":2,"path":"/b.txt","bytes":1,"selected":0}]"#
        MockURLProtocol.setHandler(scriptedHandler(files: junk,
                                                   postSelectStatus: "downloaded") { path, body in
            if path.contains("/selectFiles/") { selectBody = body }
        })
        let added = try await TorrentAdder(rd: client())
            .add(.magnet("magnet:?xt=urn:btih:cafebabe"))
        XCTAssertEqual(selectBody, "files=1%2C2")
        XCTAssertEqual(added.selectedFileIDs, [1, 2])
    }

    func testAddUncachedReportsDownloading() async throws {
        MockURLProtocol.setHandler(scriptedHandler(files: mixedPack,
                                                   postSelectStatus: "queued") { _, _ in })
        let added = try await TorrentAdder(rd: client())
            .add(.magnet("magnet:?xt=urn:btih:cafebabe"))
        XCTAssertEqual(added.outcome, .downloading(torrentID: "TID"))
    }

    func testAddDedupesByInfohash() async throws {
        nonisolated(unsafe) var addCalled = false
        let existing = #"[{"id":"OLD","filename":"x","hash":"CAFEBABE","bytes":1,"progress":100,"status":"downloaded","added":"2026-01-01T00:00:00.000Z","links":[]}]"#
        MockURLProtocol.setHandler(scriptedHandler(files: "[]", postSelectStatus: "downloaded",
                                                   existingTorrents: existing) { path, _ in
            if path.hasSuffix("/addMagnet") { addCalled = true }
        })
        let added = try await TorrentAdder(rd: client())
            .add(.magnet("magnet:?xt=urn:btih:cafebabe&dn=x"))
        XCTAssertEqual(added.outcome, .alreadyInLibrary(torrentID: "OLD"))
        XCTAssertFalse(addCalled)
    }

    func testTorrentFileAddSkipsDedupe() async throws {
        nonisolated(unsafe) var listedTorrents = false
        MockURLProtocol.setHandler(scriptedHandler(files: mixedPack,
                                                   postSelectStatus: "downloaded") { path, _ in
            if path.hasSuffix("/torrents") { listedTorrents = true }
        })
        _ = try await TorrentAdder(rd: client()).add(.file(Data([0x64])))
        XCTAssertFalse(listedTorrents)
    }

    func testReselectDeletesAndReAdds() async throws {
        nonisolated(unsafe) var calls: [String] = []
        nonisolated(unsafe) var selectBody: String?
        MockURLProtocol.setHandler(scriptedHandler(files: mixedPack,
                                                   postSelectStatus: "downloaded") { path, body in
            calls.append(path)
            if path.contains("/selectFiles/") { selectBody = body }
        })
        let added = try await TorrentAdder(rd: client())
            .reselect(source: .magnet("magnet:?xt=urn:btih:cafebabe"),
                      torrentID: "STALE", fileIDs: [1])
        XCTAssertTrue(calls.contains("/rest/1.0/torrents/delete/STALE"))
        XCTAssertTrue(calls.contains("/rest/1.0/torrents/addMagnet"))
        XCTAssertEqual(selectBody, "files=1")
        XCTAssertEqual(added.selectedFileIDs, [1])
    }

    func testInfohashParsing() {
        XCTAssertEqual(TorrentAdder.infohash(fromMagnet:
            "magnet:?xt=urn:btih:CAFEBABE123&dn=Some.Show"), "cafebabe123")
        XCTAssertNil(TorrentAdder.infohash(fromMagnet: "https://example.com/not-a-magnet"))
        XCTAssertNil(TorrentAdder.infohash(fromMagnet: "magnet:?dn=no-xt"))
    }

    // MARK: infohash from resolver URLs

    func testInfohashFromResolverURL() {
        // Torrentio-style: {base}/realdebrid/{apikey}/{hash}/{fileIdx}/{name}
        let url = URL(string: "https://torrentio.strem.fun/realdebrid/SOMEAPIKEY123/35790E66E077E90A14A067A983A3568E56C95333/null/0/My.Show.S01E01.mkv")!
        XCTAssertEqual(TorrentAdder.infohash(inURL: url),
                       "35790e66e077e90a14a067a983a3568e56c95333")
    }

    func testInfohashFromResolverURLNilWhenAbsent() {
        let url = URL(string: "https://resolver.example/play/My.Movie.2023.1080p.mkv")!
        XCTAssertNil(TorrentAdder.infohash(inURL: url))
    }

    // MARK: completeSelection

    /// A resolver-added torrent stuck at waiting_files_selection gets its
    /// video files selected so RD actually starts downloading.
    func testCompleteSelectionSelectsVideoFilesOnStuckTorrent() async throws {
        nonisolated(unsafe) var selectBody: String?
        MockURLProtocol.setHandler(scriptedHandler(files: mixedPack,
                                                   postSelectStatus: "downloading") { path, body in
            if path.contains("/selectFiles/") { selectBody = body }
        })
        try await TorrentAdder(rd: client()).completeSelection(torrentID: "TID")
        XCTAssertEqual(selectBody, "files=1%2C4")
    }

    /// Metadata may still be resolving when we arrive — wait it out, then select.
    func testCompleteSelectionWaitsOutMagnetConversion() async throws {
        nonisolated(unsafe) var infoCalls = 0
        nonisolated(unsafe) var selectBody: String?
        let files = mixedPack
        MockURLProtocol.setHandler { req in
            let path = req.url!.path
            if path.contains("/selectFiles/") {
                selectBody = req.bodyData.flatMap { String(data: $0, encoding: .utf8) }
                return .init(status: 204)
            }
            if path.contains("/torrents/info/") {
                infoCalls += 1
                let status = infoCalls == 1 ? "magnet_conversion" : "waiting_files_selection"
                return .json(#"{"id":"TID","filename":"pack","bytes":9,"progress":0,"status":"\#(status)","files":\#(files),"links":[]}"#)
            }
            return .init(status: 404)
        }
        try await TorrentAdder(rd: client()).completeSelection(torrentID: "TID")
        XCTAssertEqual(selectBody, "files=1%2C4")
    }

    /// Already-selected torrents (downloading/downloaded) must be left alone —
    /// RD rejects selectFiles on them (action_already_done).
    func testCompleteSelectionNoopsWhenAlreadyStarted() async throws {
        nonisolated(unsafe) var selectCalled = false
        MockURLProtocol.setHandler { req in
            let path = req.url!.path
            if path.contains("/selectFiles/") { selectCalled = true; return .init(status: 204) }
            if path.contains("/torrents/info/") {
                return .json(#"{"id":"TID","filename":"pack","bytes":9,"progress":10,"status":"downloading","files":[],"links":[]}"#)
            }
            return .init(status: 404)
        }
        try await TorrentAdder(rd: client()).completeSelection(torrentID: "TID")
        XCTAssertFalse(selectCalled)
    }
}
