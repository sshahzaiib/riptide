import XCTest
@testable import StreamCore

final class RealDebridErrorMessageTests: XCTestCase {
    func testLocalizedDescriptionIsReadable() {
        let text = (RealDebridError.infringingFile as Error).localizedDescription
        XCTAssertEqual(text, "Real-Debrid has blocked this file. Try another version.")
        XCTAssertFalse((RealDebridError.api(code: 9, message: "") as Error).localizedDescription.contains("StreamCore"))
    }
}
