import XCTest
@testable import StreamCore

final class AllDebridClientTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.setHandler(nil)
        super.tearDown()
    }

    private func client() -> AllDebridClient {
        AllDebridClient(token: "adkey", session: .mocked(),
                        config: .init(maxRetries: 2, retryBaseDelay: 0.001,
                                      pollInterval: 0.001, pollTimeout: 1),
                        sleep: { _ in })
    }

    func testMagnetUploadRequestShape() async throws {
        nonisolated(unsafe) var captured: (path: String?, auth: String?, body: String?)
        MockURLProtocol.setHandler { req in
            captured = (req.url?.path,
                        req.value(forHTTPHeaderField: "Authorization"),
                        req.bodyData.flatMap { String(data: $0, encoding: .utf8) })
            return .json(#"{"status":"success","data":{"magnets":[{"id":123,"ready":false,"hash":"cafebabe","name":"Pack","size":900}]}}"#)
        }
        let up = try await client().magnetUpload("magnet:?xt=urn:btih:cafebabe")
        XCTAssertEqual(captured.path, "/v4/magnet/upload")
        XCTAssertEqual(captured.auth, "Bearer adkey")
        XCTAssertEqual(captured.body, "magnets%5B%5D=magnet%3A%3Fxt%3Durn%3Abtih%3Acafebabe")
        XCTAssertEqual(up.id, 123)
        XCTAssertEqual(up.ready, false)
        XCTAssertEqual(up.hash, "cafebabe")
    }

    func testCachedUploadReportsReady() async throws {
        MockURLProtocol.setHandler { _ in
            .json(#"{"status":"success","data":{"magnets":[{"id":9,"ready":true}]}}"#)
        }
        let up = try await client().magnetUpload("magnet:?xt=urn:btih:beef")
        XCTAssertEqual(up.ready, true)
    }

    func testAuthErrorMapsToAuthFailed() async {
        MockURLProtocol.setHandler { _ in
            .json(#"{"status":"error","error":{"code":"AUTH_BAD_APIKEY","message":"The auth apikey is invalid"}}"#)
        }
        do { _ = try await client().magnetUpload("magnet:?xt=urn:btih:x"); XCTFail("expected throw") }
        catch AllDebridError.authFailed {} catch { XCTFail("wrong error \(error)") }
    }

    /// AD reports per-magnet failures INSIDE the magnets array, with a
    /// success top-level envelope.
    func testPerMagnetErrorMapsToMagnetRejected() async {
        MockURLProtocol.setHandler { _ in
            .json(#"{"status":"success","data":{"magnets":[{"magnet":"bad","error":{"code":"MAGNET_INVALID_URI","message":"Invalid magnet"}}]}}"#)
        }
        do { _ = try await client().magnetUpload("bad"); XCTFail("expected throw") }
        catch AllDebridError.magnetRejected(let code) { XCTAssertEqual(code, "MAGNET_INVALID_URI") }
        catch { XCTFail("wrong error \(error)") }
    }

    func testRateLimitRetriesThenSucceeds() async throws {
        nonisolated(unsafe) var calls = 0
        MockURLProtocol.setHandler { _ in
            calls += 1
            if calls == 1 { return .init(status: 429) }
            return .json(#"{"status":"success","data":{"magnets":[{"id":1,"ready":true}]}}"#)
        }
        _ = try await client().magnetUpload("magnet:?xt=urn:btih:x")
        XCTAssertEqual(calls, 2)
    }

    func testRateLimitExhaustsRetries() async {
        MockURLProtocol.setHandler { _ in .init(status: 429) }
        do { _ = try await client().magnetUpload("magnet:?xt=urn:btih:x"); XCTFail("expected throw") }
        catch AllDebridError.rateLimited {} catch { XCTFail("wrong error \(error)") }
    }

    func testMagnetStatusListDecodesAndRoutes() async throws {
        nonisolated(unsafe) var path: String?
        MockURLProtocol.setHandler { req in
            path = req.url?.path
            return .json(#"{"status":"success","data":{"magnets":[{"id":1,"filename":"a.mkv","size":100,"status":"Ready","statusCode":4},{"id":2,"filename":"b","size":50,"status":"Downloading","statusCode":1,"downloaded":25}]}}"#)
        }
        let list = try await client().magnetStatusList()
        XCTAssertEqual(path, "/v4.1/magnet/status")
        XCTAssertEqual(list.map(\.id), [1, 2])
        XCTAssertEqual(list[0].statusCode, 4)
        XCTAssertEqual(list[1].downloaded, 25)
    }

    /// Querying one id returns data.magnets as a single OBJECT, not an array.
    func testMagnetStatusSingleObjectDecodes() async throws {
        nonisolated(unsafe) var body: String?
        MockURLProtocol.setHandler { req in
            body = req.bodyData.flatMap { String(data: $0, encoding: .utf8) }
            return .json(#"{"status":"success","data":{"magnets":{"id":7,"filename":"x.mkv","size":10,"status":"Ready","statusCode":4}}}"#)
        }
        let magnet = try await client().magnetStatus(id: 7)
        XCTAssertEqual(body, "id=7")
        XCTAssertEqual(magnet.id, 7)
        XCTAssertEqual(magnet.statusCode, 4)
    }

    func testMagnetFilesFlattensTreeToVideoFiles() async throws {
        MockURLProtocol.setHandler { _ in
            .json(#"{"status":"success","data":{"magnets":[{"id":5,"files":[{"n":"Pack","e":[{"n":"S01E01.mkv","s":900,"l":"https://alldebrid.com/f/aaa"},{"n":"info.nfo","s":1,"l":"https://alldebrid.com/f/bbb"}]},{"n":"Sample.mp4","s":10,"l":"https://alldebrid.com/f/ccc"}]}]}}"#)
        }
        let files = try await client().magnetFiles(ids: [5])
        XCTAssertEqual(files.count, 1)
        let flat = ADFileNode.flattenVideoFiles(files[0].files)
        XCTAssertEqual(flat.map(\.name), ["S01E01.mkv", "Sample.mp4"])
        XCTAssertEqual(flat[0].path, "Pack/S01E01.mkv")   // folder joined into path
        XCTAssertEqual(flat[0].link, "https://alldebrid.com/f/aaa")
        // .nfo is skipped (not a video extension); sample FILTERING is the
        // parser's job downstream — flatten keeps every video file.
    }

    func testMagnetFilesOmitFilesKeyDefaultsToEmpty() async throws {
        MockURLProtocol.setHandler { _ in
            .json(#"{"status":"success","data":{"magnets":[{"id":5}]}}"#)
        }
        let files = try await client().magnetFiles(ids: [5])
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].id, 5)
        XCTAssertEqual(files[0].files, [])
    }

    func testFlattenVideoFilesHandlesLeafWithEmptyChildren() {
        let node = ADFileNode(n: "Movie.mkv", s: 100, l: "https://alldebrid.com/f/link", e: [])
        let flat = ADFileNode.flattenVideoFiles([node])
        XCTAssertEqual(flat.count, 1)
        XCTAssertEqual(flat[0].name, "Movie.mkv")
        XCTAssertEqual(flat[0].link, "https://alldebrid.com/f/link")
        XCTAssertEqual(flat[0].path, "Movie.mkv")
    }

    func testUnlockReturnsDirectURL() async throws {
        nonisolated(unsafe) var body: String?
        MockURLProtocol.setHandler { req in
            body = req.bodyData.flatMap { String(data: $0, encoding: .utf8) }
            return .json(#"{"status":"success","data":{"link":"https://x.debrid.it/dl/abc/file.mkv"}}"#)
        }
        let url = try await client().unlock(link: "https://alldebrid.com/f/aaa")
        XCTAssertEqual(body, "link=https%3A%2F%2Falldebrid.com%2Ff%2Faaa")
        XCTAssertEqual(url.absoluteString, "https://x.debrid.it/dl/abc/file.mkv")
    }

    func testUnlockPercentEncodesUnencodedSpaces() async throws {
        MockURLProtocol.setHandler { _ in
            .json(#"{"status":"success","data":{"link":"https://host/My Movie (2023).mkv"}}"#)
        }
        let url = try await client().unlock(link: "https://alldebrid.com/f/aaa")
        XCTAssertEqual(url.absoluteString, "https://host/My%20Movie%20(2023).mkv")
    }

    func testMagnetDeleteRoutes() async throws {
        nonisolated(unsafe) var captured: (path: String?, body: String?)
        MockURLProtocol.setHandler { req in
            captured = (req.url?.path, req.bodyData.flatMap { String(data: $0, encoding: .utf8) })
            return .json(#"{"status":"success","data":{"message":"Magnet was successfully deleted"}}"#)
        }
        try await client().magnetDelete(id: 42)
        XCTAssertEqual(captured.path, "/v4/magnet/delete")
        XCTAssertEqual(captured.body, "id=42")
    }
}

