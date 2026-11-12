import XCTest
@testable import StreamCore

final class StreamResultParserTests: XCTestCase {
    private func stream(name: String? = nil, title: String? = nil,
                        description: String? = nil,
                        videoSize: Int64? = nil) -> AddonStream {
        AddonStream(name: name, title: title, description: description,
                    url: "https://host/x.mkv", infoHash: nil,
                    behaviorHints: videoSize.map {
                        AddonStream.BehaviorHints(filename: nil, videoSize: $0)
                    })
    }

    func testTorrentioCached4K() {
        let meta = StreamResultParser.parse(stream(
            name: "[RD+] Torrentio\n4k",
            title: "Movie.2023.2160p.WEB-DL.DDP5.1\n👤 89 💾 4.29 GB ⚙️ RARBG"))
        XCTAssertEqual(meta.cached, true)
        XCTAssertEqual(meta.resolution, "2160p")
        XCTAssertEqual(meta.sizeBytes, Int64(4.29 * 1_073_741_824))
    }

    func testTorrentioUncachedDownload() {
        let meta = StreamResultParser.parse(stream(
            name: "[RD download] Torrentio\n1080p",
            title: "Movie.2023.1080p\n👤 4 💾 1.5 GB"))
        XCTAssertEqual(meta.cached, false)
        XCTAssertEqual(meta.resolution, "1080p")
    }

    func testAIOStreamsLightningCached() {
        let meta = StreamResultParser.parse(stream(
            name: "⚡ AIOStreams 720P",
            description: "Movie 2023 720p BluRay 700 MB"))
        XCTAssertEqual(meta.cached, true)
        XCTAssertEqual(meta.resolution, "720p")
        XCTAssertEqual(meta.sizeBytes, Int64(700 * 1_048_576))
    }

    func testBehaviorHintsVideoSizeWins() {
        let meta = StreamResultParser.parse(stream(
            name: "[RD+] X\n1080p", title: "💾 4.29 GB", videoSize: 999))
        XCTAssertEqual(meta.sizeBytes, 999)
    }

    func testJunkYieldsNils() {
        let meta = StreamResultParser.parse(stream(name: "Some Stream", title: "no metadata here"))
        XCTAssertNil(meta.cached)
        XCTAssertNil(meta.resolution)
        XCTAssertNil(meta.sizeBytes)
    }

    func testDebridServiceDetection() {
        XCTAssertEqual(StreamResultParser.parse(stream(name: "[RD+] Torrentio")).service, .realDebrid)
        XCTAssertEqual(StreamResultParser.parse(stream(name: "[AD+] Torrentio")).service, .allDebrid)
        XCTAssertEqual(StreamResultParser.parse(stream(name: "AIOStreams | AllDebrid ⚡")).service, .allDebrid)
        XCTAssertEqual(StreamResultParser.parse(stream(name: "Real-Debrid cached")).service, .realDebrid)
        XCTAssertEqual(StreamResultParser.parse(stream(name: "realdebrid cached")).service, .realDebrid)
        XCTAssertNil(StreamResultParser.parse(stream(name: "both RD and AD here")).service)
        XCTAssertNil(StreamResultParser.parse(stream(name: "4K HDR BluRay")).service)
        XCTAssertNil(StreamResultParser.parse(stream(name: "plain title mentioning neither")).service)

        // Word boundaries test cases
        XCTAssertNil(StreamResultParser.parse(stream(name: "HDR")).service)
        XCTAssertNil(StreamResultParser.parse(stream(name: "SHADOW")).service)
        XCTAssertNil(StreamResultParser.parse(stream(name: "1080p")).service)
        XCTAssertEqual(StreamResultParser.parse(stream(name: "[RD+]")).service, .realDebrid)
        XCTAssertEqual(StreamResultParser.parse(stream(name: "RD download")).service, .realDebrid)
        XCTAssertEqual(StreamResultParser.parse(stream(name: "⚡ AD")).service, .allDebrid)
    }

    // MARK: Comet (self-hosted) — shapes captured from a live instance

    func testCometCached() {
        let meta = StreamResultParser.parse(stream(
            name: "[RD⚡] Comet 2160p",
            description: "📄 The.Godfather.1972.2160p.REMUX.mkv\n💾 78.3 GB 🔎 Comet|StremThru",
            videoSize: 84_122_195_722))
        XCTAssertEqual(meta.cached, true)
        XCTAssertEqual(meta.resolution, "2160p")
        XCTAssertEqual(meta.sizeBytes, 84_122_195_722)
        XCTAssertEqual(meta.service, .realDebrid)
    }

    func testCometUncachedDownArrow() {
        let meta = StreamResultParser.parse(stream(name: "[AD⬇️] Comet 1080p"))
        XCTAssertEqual(meta.cached, false)
        XCTAssertEqual(meta.service, .allDebrid)
    }

    func testCometSyncEntryIsAnActionNotAStream() {
        let sync = AddonStream(name: "[RD🔄] Comet Sync",
                               title: nil, description: "Sync debrid account library now.",
                               url: "http://192.168.1.2:8000/s/t/c/debrid-sync/0",
                               infoHash: nil, behaviorHints: nil)
        XCTAssertTrue(sync.isAction)
        XCTAssertFalse(stream(name: "[RD⚡] Comet 2160p").isAction)
    }

    // MARK: Ordering — the user's addon order outranks quality

    func testFirstAddonOutranksBetterStreamFromSecondAddon() {
        let small = ParsedStreamMeta(resolution: "720p", sizeBytes: 1, cached: true)
        let big = ParsedStreamMeta(resolution: "2160p", sizeBytes: 99, cached: true)
        XCTAssertTrue(small.sortKey(addonIndex: 0) < big.sortKey(addonIndex: 1))
    }

    func testWithinAnAddonCachedThenResolutionThenSize() {
        let cached720 = ParsedStreamMeta(resolution: "720p", cached: true)
        let unknown4k = ParsedStreamMeta(resolution: "2160p", cached: nil)
        let uncached4k = ParsedStreamMeta(resolution: "2160p", cached: false)
        XCTAssertTrue(cached720.sortKey(addonIndex: 0) < unknown4k.sortKey(addonIndex: 0))
        XCTAssertTrue(unknown4k.sortKey(addonIndex: 0) < uncached4k.sortKey(addonIndex: 0))
        let big = ParsedStreamMeta(resolution: "1080p", sizeBytes: 9, cached: true)
        let little = ParsedStreamMeta(resolution: "1080p", sizeBytes: 2, cached: true)
        XCTAssertTrue(big.sortKey(addonIndex: 0) < little.sortKey(addonIndex: 0))
        XCTAssertTrue(big.sortKey(addonIndex: 0) < cached720.sortKey(addonIndex: 0))
    }

    func testActionDetectedByURLAlone() {
        let sync = AddonStream(name: "Sync library", title: nil, description: nil,
                               url: "http://host/s/t/c/debrid-sync/1", infoHash: nil, behaviorHints: nil)
        XCTAssertTrue(sync.isAction)
    }

    func testDownArrowAsPeerCountDoesNotMeanUncached() {
        let meta = StreamResultParser.parse(stream(
            name: "[RD+] MediaFusion 1080p", description: "Movie.2023.1080p\n👤 20 ⬇️ 5 💾 2 GB"))
        XCTAssertEqual(meta.cached, true)
    }
}
