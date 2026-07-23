import XCTest
@testable import StreamCore

final class MetadataCacheTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testMissThenHit() async {
        let cache = MetadataCache(directory: dir)
        let miss = await cache.data(for: "k", ttl: 60)
        XCTAssertNil(miss)
        await cache.store(Data("hello".utf8), for: "k")
        let hit = await cache.data(for: "k", ttl: 60)
        XCTAssertEqual(hit, Data("hello".utf8))
    }

    func testDiskPersistsAcrossInstances() async {
        await MetadataCache(directory: dir).store(Data("x".utf8), for: "k")
        let second = MetadataCache(directory: dir)   // fresh memory
        let hit = await second.data(for: "k", ttl: 60)
        XCTAssertEqual(hit, Data("x".utf8))
    }

    func testTTLExpiry() async {
        await MetadataCache(directory: dir).store(Data("x".utf8), for: "k")
        // Reader whose clock is 1 hour ahead: a 60s TTL entry is expired.
        let future = MetadataCache(directory: dir,
                                   now: { Date(timeIntervalSinceNow: 3600) })
        let expired = await future.data(for: "k", ttl: 60)
        XCTAssertNil(expired)
        let alive = await future.data(for: "k", ttl: 7200)
        XCTAssertEqual(alive, Data("x".utf8))
    }

    func testClearAndDiskUsage() async {
        let cache = MetadataCache(directory: dir)
        await cache.store(Data(repeating: 7, count: 1000), for: "k")
        let used = await cache.diskBytesUsed()
        XCTAssertGreaterThanOrEqual(used, 1000)
        await cache.clear()
        let after = await cache.diskBytesUsed()
        XCTAssertEqual(after, 0)
        let miss = await cache.data(for: "k", ttl: 60)
        XCTAssertNil(miss)
    }

    func testSweepRemovesOldFiles() async {
        let cache = MetadataCache(directory: dir)
        await cache.store(Data("old".utf8), for: "k")
        // Sweeper 1 hour in the future removes anything older than 60s.
        let future = MetadataCache(directory: dir,
                                   now: { Date(timeIntervalSinceNow: 3600) })
        await future.sweep(olderThan: 60)
        let gone = await MetadataCache(directory: dir).data(for: "k", ttl: .infinity)
        XCTAssertNil(gone)
    }
}
