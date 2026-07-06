import XCTest
@testable import StreamCore

final class SmokeTests: XCTestCase {
    func testPackageBuildsAndLinks() {
        XCTAssertEqual(StreamCore.version, "0.1.0")
    }
}
