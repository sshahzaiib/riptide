// Tests/StreamCoreTests/DebridServiceTests.swift
import XCTest
@testable import StreamCore

final class DebridServiceTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.setHandler(nil)
        super.tearDown()
    }

    // MARK: DebridServiceID.detect

    func testDetectFromAddonURL() {
        XCTAssertEqual(DebridServiceID.detect(fromAddonURL:
            URL(string: "https://torrentio.strem.fun/realdebrid=KEY/manifest.json")!), .realDebrid)
        XCTAssertEqual(DebridServiceID.detect(fromAddonURL:
            URL(string: "https://torrentio.strem.fun/alldebrid=KEY")!), .allDebrid)
        XCTAssertEqual(DebridServiceID.detect(fromAddonURL:
            URL(string: "https://example.com/REAL-DEBRID/x")!), .realDebrid)
        XCTAssertNil(DebridServiceID.detect(fromAddonURL:
            URL(string: "https://aiostreams.elfhosted.com/opaque")!))
    }

    // MARK: RealDebridService

    private func rdService() -> RealDebridService {
        RealDebridService(rd: RealDebridClient(token: "tok", session: .mocked(),
                                               config: .init(pollInterval: 0.001, pollTimeout: 1),
                                               sleep: { _ in }))
    }

    func testRDTransferStatusMapping() async throws {
        nonisolated(unsafe) var status = "downloading"
        MockURLProtocol.setHandler { req in
            guard req.url!.path.contains("/torrents/info/") else { return .init(status: 404) }
            return .json(#"{"id":"T1","filename":"x","bytes":9,"progress":40,"status":"\#(status)","files":[],"links":[]}"#)
        }
        var transfer = try await rdService().transferStatus(id: "T1")
        XCTAssertEqual(transfer.status, .processing(progress: 40))
        status = "downloaded"
        transfer = try await rdService().transferStatus(id: "T1")
        XCTAssertEqual(transfer.status, .ready)
        status = "dead"
        transfer = try await rdService().transferStatus(id: "T1")
        XCTAssertEqual(transfer.status, .failed("dead"))
    }

    func testRDUnrestrictReturnsDownloadURL() async throws {
        MockURLProtocol.setHandler { _ in
            .json(#"{"id":"u1","filename":"f.mkv","filesize":9,"host":"rd","download":"https://rd.example/dl/f.mkv","streamable":1}"#)
        }
        let url = try await rdService().unrestrict(link: "https://real-debrid.com/d/xyz")
        XCTAssertEqual(url.absoluteString, "https://rd.example/dl/f.mkv")
    }

    func testRDTransferIDs() async throws {
        MockURLProtocol.setHandler { _ in
            .json(#"[{"id":"A","filename":"a","hash":"h1","bytes":1,"progress":100,"status":"downloaded","added":"2026-01-01T00:00:00.000Z","links":[]}]"#)
        }
        let ids = try await rdService().transferIDs()
        XCTAssertEqual(ids, ["A"])
    }

    // MARK: AllDebridService

    private func adService() -> AllDebridService {
        AllDebridService(client: AllDebridClient(token: "adkey", session: .mocked(),
                                                 config: .init(maxRetries: 0, retryBaseDelay: 0.001,
                                                               pollInterval: 0.001, pollTimeout: 1),
                                                 sleep: { _ in }))
    }

    func testADAddMagnetMapsReadyAndProcessing() async throws {
        MockURLProtocol.setHandler { _ in
            .json(#"{"status":"success","data":{"magnets":[{"id":11,"ready":true}]}}"#)
        }
        var transfer = try await adService().addMagnet("magnet:?xt=urn:btih:x")
        XCTAssertEqual(transfer, DebridTransfer(id: "11", status: .ready))

        MockURLProtocol.setHandler { _ in
            .json(#"{"status":"success","data":{"magnets":[{"id":12,"ready":false}]}}"#)
        }
        transfer = try await adService().addMagnet("magnet:?xt=urn:btih:y")
        XCTAssertEqual(transfer, DebridTransfer(id: "12", status: .processing(progress: 0)))
    }

    func testADTransferStatusMapsStatusCodes() async throws {
        nonisolated(unsafe) var payload = #"{"id":3,"filename":"f","size":100,"status":"Downloading","statusCode":1,"downloaded":50}"#
        MockURLProtocol.setHandler { _ in
            .json(#"{"status":"success","data":{"magnets":\#(payload)}}"#)
        }
        var transfer = try await adService().transferStatus(id: "3")
        XCTAssertEqual(transfer.status, .processing(progress: 50))   // downloaded/size*100
        payload = #"{"id":3,"filename":"f","size":100,"status":"Ready","statusCode":4}"#
        transfer = try await adService().transferStatus(id: "3")
        XCTAssertEqual(transfer.status, .ready)
        payload = #"{"id":3,"filename":"f","size":100,"status":"Error","statusCode":7}"#
        transfer = try await adService().transferStatus(id: "3")
        XCTAssertEqual(transfer.status, .failed("Error"))
    }

    func testADNonNumericTransferIDThrows() async {
        do { _ = try await adService().transferStatus(id: "not-a-number"); XCTFail("expected throw") }
        catch AllDebridError.badResponse {} catch { XCTFail("wrong error \(error)") }
    }
}
