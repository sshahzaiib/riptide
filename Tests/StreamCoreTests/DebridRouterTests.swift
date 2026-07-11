import XCTest
@testable import StreamCore

/// Scripted in-memory DebridService — no networking.
private struct StubService: DebridService {
    let serviceID: DebridServiceID
    var supportsAdds: Bool { true }
    let addResult: @Sendable (String) throws -> DebridTransfer
    let recorder: @Sendable (DebridServiceID) -> Void

    func addMagnet(_ magnet: String) async throws -> DebridTransfer {
        recorder(serviceID)
        return try addResult(magnet)
    }
    func transferStatus(id: String) async throws -> DebridTransfer {
        DebridTransfer(id: id, status: .ready)
    }
    func transferIDs() async throws -> Set<String> { [] }
    func unrestrict(link: String) async throws -> URL { URL(string: "https://stub")! }
    func delete(id: String) async throws {}
}

final class DebridRouterTests: XCTestCase {
    private final class CallLog: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [DebridServiceID] = []
        func record(_ id: DebridServiceID) { lock.lock(); calls.append(id); lock.unlock() }
        var order: [DebridServiceID] { lock.lock(); defer { lock.unlock() }; return calls }
    }

    private func stub(_ id: DebridServiceID, log: CallLog,
                      result: @escaping @Sendable (String) throws -> DebridTransfer
                          = { _ in DebridTransfer(id: "ok", status: .ready) }) -> StubService {
        StubService(serviceID: id, addResult: result, recorder: { log.record($0) })
    }

    func testPrefersTargetService() async throws {
        let log = CallLog()
        let router = DebridRouter(rd: stub(.realDebrid, log: log), ad: stub(.allDebrid, log: log))
        let placed = try await router.addWithFailover(magnet: "m", preferring: .allDebrid)
        XCTAssertEqual(placed.serviceID, .allDebrid)
        XCTAssertEqual(log.order, [.allDebrid])
    }

    func testNilPreferenceDefaultsToRD() async throws {
        let log = CallLog()
        let router = DebridRouter(rd: stub(.realDebrid, log: log), ad: stub(.allDebrid, log: log))
        let placed = try await router.addWithFailover(magnet: "m", preferring: nil)
        XCTAssertEqual(placed.serviceID, .realDebrid)
    }

    func testFailsOverOnceOnTerminalError() async throws {
        let log = CallLog()
        let router = DebridRouter(
            rd: stub(.realDebrid, log: log, result: { _ in throw RealDebridError.torrentFailed(status: "dead") }),
            ad: stub(.allDebrid, log: log))
        let placed = try await router.addWithFailover(magnet: "m", preferring: .realDebrid)
        XCTAssertEqual(placed.serviceID, .allDebrid)
        XCTAssertEqual(log.order, [.realDebrid, .allDebrid])
    }

    func testFailedTransferStatusAlsoFailsOver() async throws {
        let log = CallLog()
        let router = DebridRouter(
            rd: stub(.realDebrid, log: log, result: { _ in DebridTransfer(id: "x", status: .failed("dead")) }),
            ad: stub(.allDebrid, log: log))
        let placed = try await router.addWithFailover(magnet: "m", preferring: .realDebrid)
        XCTAssertEqual(placed.serviceID, .allDebrid)
    }

    func testCancellationNeverFailsOver() async {
        let log = CallLog()
        let router = DebridRouter(
            rd: stub(.realDebrid, log: log, result: { _ in throw CancellationError() }),
            ad: stub(.allDebrid, log: log))
        do {
            _ = try await router.addWithFailover(magnet: "m", preferring: .realDebrid)
            XCTFail("expected throw")
        } catch is CancellationError {
            XCTAssertEqual(log.order, [.realDebrid])   // AD never tried
        } catch { XCTFail("wrong error \(error)") }
    }

    func testNoFallbackConfiguredPropagatesError() async {
        let log = CallLog()
        let router = DebridRouter(
            rd: stub(.realDebrid, log: log, result: { _ in throw RealDebridError.torrentFailed(status: "dead") }),
            ad: nil)
        do {
            _ = try await router.addWithFailover(magnet: "m", preferring: .realDebrid)
            XCTFail("expected throw")
        } catch RealDebridError.torrentFailed { } catch { XCTFail("wrong error \(error)") }
    }

    func testBothFailingThrowsSecondError() async {
        let log = CallLog()
        let router = DebridRouter(
            rd: stub(.realDebrid, log: log, result: { _ in throw RealDebridError.torrentFailed(status: "dead") }),
            ad: stub(.allDebrid, log: log, result: { _ in throw AllDebridError.magnetRejected(code: "MAGNET_NO_SERVER") }))
        do {
            _ = try await router.addWithFailover(magnet: "m", preferring: .realDebrid)
            XCTFail("expected throw")
        } catch AllDebridError.magnetRejected { XCTAssertEqual(log.order, [.realDebrid, .allDebrid]) }
        catch { XCTFail("wrong error \(error)") }
    }

    func testNoServicesThrows() async {
        let router = DebridRouter(rd: nil, ad: nil)
        do { _ = try await router.addWithFailover(magnet: "m", preferring: nil); XCTFail("expected throw") }
        catch DebridRouterError.noServiceConfigured {} catch { XCTFail("wrong error \(error)") }
    }
}
