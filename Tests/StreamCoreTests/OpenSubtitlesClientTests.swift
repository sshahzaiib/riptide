import XCTest
@testable import StreamCore

final class OpenSubtitlesClientTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.setHandler(nil)
        super.tearDown()
    }

    private func client() -> OpenSubtitlesClient {
        OpenSubtitlesClient(apiKey: "KEY", session: .mocked())
    }

    private static let searchJSON = """
    {"total_count":1,"data":[
      {"id":"7061","type":"subtitle","attributes":{
        "language":"en","release":"Breaking.Bad.S05E14.720p",
        "files":[{"file_id":911,"file_name":"ozymandias.srt"}]}},
      {"id":"7062","type":"subtitle","attributes":{
        "language":"en","release":"no-files-entry","files":[]}}]}
    """

    func testSearchRequestAndDecode() async throws {
        nonisolated(unsafe) var seen: URLRequest?
        MockURLProtocol.setHandler { request in
            seen = request
            return .json(Self.searchJSON)
        }
        let results = try await client().search(query: "Breaking Bad", season: 5, episode: 14)
        // Entries without files are dropped — nothing downloadable.
        XCTAssertEqual(results, [SubtitleResult(id: "7061", language: "en",
                                                release: "Breaking.Bad.S05E14.720p",
                                                fileID: 911, fileName: "ozymandias.srt")])
        let req = try XCTUnwrap(seen)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Api-Key"), "KEY")
        XCTAssertNotNil(req.value(forHTTPHeaderField: "User-Agent"))
        let comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
        XCTAssertTrue(comps.path.hasSuffix("/subtitles"))
        XCTAssertEqual(Set(comps.queryItems ?? []),
                       [URLQueryItem(name: "episode_number", value: "14"),
                        URLQueryItem(name: "languages", value: "en"),
                        URLQueryItem(name: "query", value: "Breaking Bad"),
                        URLQueryItem(name: "season_number", value: "5")])
    }

    func testDownloadWritesFile() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("riptide-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        MockURLProtocol.setHandler { request in
            if request.url!.path.hasSuffix("/download") {
                return .json(#"{"link":"https://dl.opensubtitles.com/f/911.srt","file_name":"ozymandias.srt"}"#)
            }
            return .json("1\n00:00:01,000 --> 00:00:02,000\nhello\n")
        }
        let fileURL = try await client().downloadSubtitle(fileID: 911, into: dir)
        XCTAssertEqual(fileURL.lastPathComponent, "ozymandias.srt")
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(content.contains("hello"))
    }

    func testQuotaExceededMapsToError() async {
        MockURLProtocol.setHandler { _ in .json(#"{"message":"quota"}"#, status: 406) }
        do {
            _ = try await client().search(query: "x", season: nil, episode: nil)
            XCTFail("expected throw")
        } catch let e as OpenSubtitlesError {
            XCTAssertEqual(e, .quotaExceeded)
        } catch { XCTFail("wrong error: \(error)") }
    }
}
