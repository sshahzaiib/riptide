import XCTest
@testable import StreamCore

final class AddonValidatorTests: XCTestCase {
    private func validator() -> AddonValidator {
        AddonValidator(client: StremioAddonClient(session: .mocked()))
    }

    override func tearDown() {
        MockURLProtocol.setHandler(nil)
        super.tearDown()
    }

    private static let goodManifest = """
    {"id":"org.test","version":"1.0.0","name":"Torrentio RD",
     "resources":[{"name":"stream","types":["movie","series"]}],"types":["movie","series"]}
    """

    /// Route by path: manifest vs stream probe.
    private func setHandler(manifest: String, streams: String,
                            manifestStatus: Int = 200) {
        MockURLProtocol.setHandler { request in
            if request.url!.path.hasSuffix("/manifest.json") {
                return .json(manifest, status: manifestStatus)
            }
            return .json(streams)
        }
    }

    func testHappyPath() async throws {
        setHandler(manifest: Self.goodManifest, streams: """
        {"streams":[{"name":"[RD+] T","url":"https://resolver/x.mkv"}]}
        """)
        let result = try await validator()
            .validate(rawURL: "https://host/cfg/manifest.json")
        XCTAssertEqual(result.baseURL.absoluteString, "https://host/cfg")
        XCTAssertEqual(result.manifest.name, "Torrentio RD")
    }

    func testInvalidURL() async {
        await assertFailure(.invalidURL) { try await self.validator().validate(rawURL: "nope") }
    }

    func testNotAnAddon() async {
        setHandler(manifest: "<html>404</html>", streams: "{}")
        await assertFailure(.notAnAddon) { try await self.validator().validate(rawURL: "https://host/x") }
    }

    func testManifest404IsNotAnAddon() async {
        setHandler(manifest: "nope", streams: "{}", manifestStatus: 404)
        await assertFailure(.notAnAddon) { try await self.validator().validate(rawURL: "https://host/x") }
    }

    func testNoStreamSupport() async {
        setHandler(manifest: """
        {"id":"x","version":"1","name":"Catalog","resources":["catalog"],"types":["movie"]}
        """, streams: "{}")
        await assertFailure(.noStreamSupport) { try await self.validator().validate(rawURL: "https://host/x") }
    }

    func testInfoHashOnlyStreamsMeansNoDebrid() async {
        setHandler(manifest: Self.goodManifest, streams: """
        {"streams":[{"name":"T","infoHash":"abc","fileIdx":0}]}
        """)
        await assertFailure(.noDebrid) { try await self.validator().validate(rawURL: "https://host/x") }
    }

    func testEmptyStreamsMeansNoDebrid() async {
        setHandler(manifest: Self.goodManifest, streams: #"{"streams":[]}"#)
        await assertFailure(.noDebrid) { try await self.validator().validate(rawURL: "https://host/x") }
    }

    /// A cancelled request must propagate as cancellation, not be masked
    /// as `.unreachable` (same passthrough as TorrentAdder, b6478c2).
    func testCancellationNotMaskedAsUnreachable() async {
        MockURLProtocol.setHandler { request in
            if request.url!.path.hasSuffix("/manifest.json") {
                return .json(Self.goodManifest)
            }
            return .failure(URLError(.cancelled))
        }
        do {
            _ = try await validator().validate(rawURL: "https://host/x")
            XCTFail("expected an error")
        } catch is CancellationError {
        } catch let e as URLError where e.code == .cancelled {
        } catch {
            XCTFail("cancellation was masked as \(error)")
        }
    }

    func testTransportErrorIsUnreachable() async {
        // No handler registered → MockURLProtocol fails the request with a URLError.
        MockURLProtocol.setHandler(nil)
        await assertFailure(.unreachable) { try await self.validator().validate(rawURL: "https://host/x") }
    }

    private func assertFailure(_ expected: AddonValidator.Failure,
                               _ body: () async throws -> AddonValidator.Result) async {
        do {
            _ = try await body()
            XCTFail("expected \(expected)")
        } catch let failure as AddonValidator.Failure {
            XCTAssertEqual(failure, expected)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
