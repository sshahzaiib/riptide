import Foundation

public enum RangeProbe {
    public static func probe(url: URL, session: URLSession = .shared) async throws -> ProbeResult {
        var filename: String?
        // 1) HEAD — fast path when it reveals both length and range support.
        var head = URLRequest(url: url); head.httpMethod = "HEAD"
        if let (_, resp) = try? await session.data(for: head),
           let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) {
            filename = http.suggestedFilename
            let len = http.expectedContentLength >= 0 ? Int64(http.expectedContentLength) : nil
            let accepts = http.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes"
            if let len, accepts {
                return ProbeResult(contentLength: len, acceptsRanges: true,
                                   suggestedFilename: filename, validator: validator(http))
            }
        }
        // 2) Fallback: a 1-byte ranged GET. A 206 + Content-Range proves range support and total size.
        var get = URLRequest(url: url); get.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (bytes, resp) = try await session.bytes(for: get)
        guard let http = resp as? HTTPURLResponse else { throw DownloadError.badResponse }
        for try await _ in bytes { }   // drain the 1-byte body to free the connection
        if filename == nil { filename = http.suggestedFilename }
        if http.statusCode == 206,
           let cr = http.value(forHTTPHeaderField: "Content-Range"),
           let total = parseContentRangeTotal(cr) {
            return ProbeResult(contentLength: total, acceptsRanges: true,
                               suggestedFilename: filename, validator: validator(http))
        }
        let len = http.expectedContentLength >= 0 ? Int64(http.expectedContentLength) : nil
        return ProbeResult(contentLength: len, acceptsRanges: false,
                           suggestedFilename: filename, validator: validator(http))
    }

    /// A strong entity validator for If-Range: ETag if present, else Last-Modified.
    private static func validator(_ http: HTTPURLResponse) -> String? {
        http.value(forHTTPHeaderField: "ETag") ?? http.value(forHTTPHeaderField: "Last-Modified")
    }

    /// "bytes 0-0/12345" → 12345 ; "*" total → nil.
    static func parseContentRangeTotal(_ value: String) -> Int64? {
        guard let slash = value.lastIndex(of: "/") else { return nil }
        return Int64(value[value.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }
}
