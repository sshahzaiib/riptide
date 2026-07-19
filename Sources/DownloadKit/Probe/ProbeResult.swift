import Foundation

public struct ProbeResult: Sendable, Equatable {
    public let contentLength: Int64?
    public let acceptsRanges: Bool
    public let suggestedFilename: String?
    public init(contentLength: Int64?, acceptsRanges: Bool, suggestedFilename: String?) {
        self.contentLength = contentLength; self.acceptsRanges = acceptsRanges; self.suggestedFilename = suggestedFilename
    }
}
