import CryptoKit
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
        let clock = MockClock()
        let cache = MetadataCache(directory: dir, now: { clock.now })
        await cache.store(Data("x".utf8), for: "k")
        
        let hit = await cache.data(for: "k", ttl: 60)
        XCTAssertEqual(hit, Data("x".utf8))
        
        // Reader whose clock is 1 hour ahead: a 60s TTL entry is expired.
        clock.now = clock.now.addingTimeInterval(3600)
        let expired = await cache.data(for: "k", ttl: 60)
        XCTAssertNil(expired)
        let alive = await cache.data(for: "k", ttl: 7200)
        XCTAssertEqual(alive, Data("x".utf8))
        
        // Additional cross-instance check
        let future = MetadataCache(directory: dir,
                                   now: { clock.now })
        let expiredCross = await future.data(for: "k", ttl: 60)
        XCTAssertNil(expiredCross)
        let aliveCross = await future.data(for: "k", ttl: 7200)
        XCTAssertEqual(aliveCross, Data("x".utf8))
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
        let clock = MockClock()
        let cache = MetadataCache(directory: dir, now: { clock.now })
        await cache.store(Data("old".utf8), for: "k")
        
        // Sweeper 1 hour in the future removes anything older than 60s.
        clock.now = clock.now.addingTimeInterval(3600)
        await cache.sweep(olderThan: 60)
        
        // Assert on the same instance
        let gone = await cache.data(for: "k", ttl: .infinity)
        XCTAssertNil(gone)
        
        // Additional cross-instance check
        let goneCross = await MetadataCache(directory: dir, now: { clock.now }).data(for: "k", ttl: .infinity)
        XCTAssertNil(goneCross)
    }

    func testRemovePrefixPurgesMemoryAndDisk() async {
        let cache = MetadataCache(directory: dir)
        await cache.store(Data("a".utf8), for: "trakt:user:abc:/sync/watchlist?")
        await cache.store(Data("b".utf8), for: "tmdb:movie/1?")
        await cache.remove(prefix: "trakt:user:")
        let purged = await cache.data(for: "trakt:user:abc:/sync/watchlist?", ttl: 3600)
        XCTAssertNil(purged)
        let kept = await cache.data(for: "tmdb:movie/1?", ttl: 3600)
        XCTAssertEqual(kept, Data("b".utf8))
        // Fresh instance over the same directory: the disk copy must be gone too.
        let rehydrated = MetadataCache(directory: dir)
        let diskPurged = await rehydrated.data(for: "trakt:user:abc:/sync/watchlist?", ttl: 3600)
        XCTAssertNil(diskPurged)
        let diskKept = await rehydrated.data(for: "tmdb:movie/1?", ttl: 3600)
        XCTAssertEqual(diskKept, Data("b".utf8))
    }

    func testNotBeforeBarrierInvalidatesOlderEntries() async {
        let clock = MockClock()
        let cache = MetadataCache(directory: dir, now: { clock.now })
        await cache.store(Data("x".utf8), for: "k")
        // Barrier after the store stamp -> miss; barrier before it -> hit.
        let stale = await cache.data(for: "k", ttl: 3600,
                                     notBefore: clock.now.addingTimeInterval(10))
        XCTAssertNil(stale)
        await cache.store(Data("x".utf8), for: "k")
        let fresh = await cache.data(for: "k", ttl: 3600,
                                     notBefore: clock.now.addingTimeInterval(-10))
        XCTAssertEqual(fresh, Data("x".utf8))
    }

    func testOldFormatHashOnlyFileReadsAsMiss() async {
        let cache = MetadataCache(directory: dir)
        // Pre-namespacing format: filename was the bare SHA-256 of the key.
        let oldName = SHA256.hash(data: Data("legacy".utf8))
            .map { String(format: "%02x", $0) }.joined() + ".json"
        try? Data("raw".utf8).write(to: dir.appendingPathComponent(oldName))
        let hit = await cache.data(for: "legacy", ttl: 3600)
        XCTAssertNil(hit)  // new naming never matches the old path
    }
}

private final class MockClock: @unchecked Sendable {
    var now = Date()
}
