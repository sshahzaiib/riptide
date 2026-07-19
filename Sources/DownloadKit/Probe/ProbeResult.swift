import Foundation

public struct ProbeResult: Sendable, Equatable {
    public let contentLength: Int64?
    public let acceptsRanges: Bool
    public let suggestedFilename: String?
    /// ETag (preferred) or Last-Modified — the entity validator for If-Range.
    public let validator: String?
    public init(contentLength: Int64?, acceptsRanges: Bool, suggestedFilename: String?,
                validator: String? = nil) {
        self.contentLength = contentLength; self.acceptsRanges = acceptsRanges
        self.suggestedFilename = suggestedFilename; self.validator = validator
    }
}
