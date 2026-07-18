import Foundation

public enum SegmentRunner {
    /// Downloads `segment`'s remaining bytes into `fileHandle`. Resumable: starts at
    /// `segment.start + segment.downloaded`. ponytail: per-byte AsyncBytes read is the
    /// v1 throughput ceiling (backpressure-friendly, so throttling stays bounded);
    /// upgrade to a delegate/Network reader with task.suspend()-based throttling if a
    /// benchmark shows it limiting fast links.
    @discardableResult
    public static func run(
        url: URL, segment: SegmentState, fileHandle: FileHandle, session: URLSession,
        limiters: [RateLimiter] = [], totalBytes: Int64, bufferSize: Int = 256 * 1024,
        onProgress: @escaping @Sendable (Int64) async -> Void
    ) async throws -> Int64 {
        if segment.isComplete { return segment.downloaded }
        let from = segment.start + segment.downloaded
        let remaining = segment.end - from + 1
        guard remaining > 0 else { return segment.downloaded }

        var request = URLRequest(url: url)
        request.setValue("bytes=\(from)-\(segment.end)", forHTTPHeaderField: "Range")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw DownloadError.badResponse }

        let writeOffset: UInt64
        var downloaded: Int64
        let cap: Int64
        switch http.statusCode {
        case 206:
            guard let cr = http.value(forHTTPHeaderField: "Content-Range"),
                  let serverStart = parseContentRangeStart(cr), serverStart == from
            else { throw DownloadError.badResponse }
            writeOffset = UInt64(from); downloaded = segment.downloaded; cap = remaining
        case 200:
            // Server ignored Range → whole body from 0. Tolerable only for the sole
            // full-object segment; rewind to 0 and reset any prior progress.
            guard segment.start == 0 && segment.end == totalBytes - 1 else { throw DownloadError.rangeUnsupported }
            if segment.downloaded > 0 { await onProgress(-segment.downloaded) }
            writeOffset = 0; downloaded = 0; cap = totalBytes
        default:
            throw DownloadError.httpStatus(http.statusCode)
        }

        try fileHandle.seek(toOffset: writeOffset)
        var got: Int64 = 0
        var buffer = Data(); buffer.reserveCapacity(bufferSize)

        func flush() async throws {
            guard !buffer.isEmpty else { return }
            try fileHandle.write(contentsOf: buffer)
            for l in limiters { await l.throttle(buffer.count) }
            downloaded += Int64(buffer.count); got += Int64(buffer.count)
            await onProgress(Int64(buffer.count))
            buffer.removeAll(keepingCapacity: true)
        }

        for try await byte in bytes {
            buffer.append(byte)
            if got + Int64(buffer.count) >= cap {     // reached the segment end — clamp, never overshoot
                try Task.checkCancellation()
                try await flush()
                break
            }
            if buffer.count >= bufferSize {
                try Task.checkCancellation()
                try await flush()
            }
        }
        try await flush()
        guard got >= cap else { throw DownloadError.badResponse }   // short/truncated transfer
        return downloaded
    }

    private static func parseContentRangeStart(_ value: String) -> Int64? {
        let v = value.trimmingCharacters(in: .whitespaces)
        guard v.hasPrefix("bytes ") else { return nil }
        let rest = v.dropFirst("bytes ".count)
        guard let dash = rest.firstIndex(of: "-") else { return nil }
        return Int64(rest[rest.startIndex..<dash])
    }
}
