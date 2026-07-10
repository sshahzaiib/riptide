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
}
