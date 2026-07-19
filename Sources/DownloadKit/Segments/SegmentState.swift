import Foundation

public struct SegmentState: Sendable, Codable, Equatable {
    public let index: Int
    public let start: Int64
    public let end: Int64        // end == start - 1 ⇒ empty
    public var downloaded: Int64

    public init(index: Int, start: Int64, end: Int64, downloaded: Int64 = 0) {
        self.index = index; self.start = start; self.end = end; self.downloaded = downloaded
    }
    public var length: Int64 { max(0, end - start + 1) }
    public var isComplete: Bool { downloaded >= length }
}
