import XCTest
@testable import StreamCore

final class TransferDiffTests: XCTestCase {
    func testDetectsProcessingToReady() {
        XCTAssertEqual(TransferDiff.newlyReady(
            previous: ["rd#A": .processing(progress: 40)],
            current: ["rd#A": .ready]), ["rd#A"])
    }

    func testFirstSightReadyNeverFires() {
        XCTAssertEqual(TransferDiff.newlyReady(
            previous: [:], current: ["rd#A": .ready]), [])
    }

    func testAlreadyReadyStaysQuiet() {
        XCTAssertEqual(TransferDiff.newlyReady(
            previous: ["rd#A": .ready], current: ["rd#A": .ready]), [])
    }

    func testFailedIsNotReady() {
        XCTAssertEqual(TransferDiff.newlyReady(
            previous: ["rd#A": .processing(progress: 10)],
            current: ["rd#A": .failed("dead")]), [])
    }

    func testMultipleTransitionsSorted() {
        XCTAssertEqual(TransferDiff.newlyReady(
            previous: ["rd#B": .processing(progress: 1),
                       "ad#1": .processing(progress: 2),
                       "rd#C": .ready],
            current: ["rd#B": .ready, "ad#1": .ready, "rd#C": .ready]),
            ["ad#1", "rd#B"])
    }
}
