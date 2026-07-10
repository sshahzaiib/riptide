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
}
