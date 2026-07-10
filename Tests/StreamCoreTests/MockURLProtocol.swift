import Foundation

/// A `URLProtocol` that returns canned responses from a registered handler.
/// The handler is invoked once per request and may be stateful (count calls)
/// to script multi-step flows. Tests run serially under `swift test` (the default;
/// we never pass `--parallel`), so the single shared handler is safe across the
/// suite. The `NSLock` only guards the handler pointer against data races — it does
/// NOT provide logical isolation, so do not enable parallel test execution.
final class MockURLProtocol: URLProtocol {
    struct Stub {
        let status: Int
        let headers: [String: String]
        let body: Data
        let error: Error?
        init(status: Int = 200, headers: [String: String] = [:], body: Data = Data(),
             error: Error? = nil) {
            self.status = status; self.headers = headers; self.body = body; self.error = error
        }
        static func json(_ string: String, status: Int = 200, headers: [String: String] = [:]) -> Stub {
            Stub(status: status, headers: headers, body: Data(string.utf8))
        }
        /// Fail the request at the transport layer instead of responding.
        static func failure(_ error: Error) -> Stub {
            Stub(error: error)
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: (@Sendable (URLRequest) -> Stub)?

    static func setHandler(_ handler: (@Sendable (URLRequest) -> Stub)?) {
        lock.lock(); _handler = handler; lock.unlock()
    }
    private static var handler: (@Sendable (URLRequest) -> Stub)? {
        lock.lock(); defer { lock.unlock() }; return _handler
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        let stub = handler(request)
        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: error); return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.status,
                                       httpVersion: "HTTP/1.1", headerFields: stub.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

extension URLSession {
    /// An ephemeral session whose only protocol is `MockURLProtocol`.
    static func mocked() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }
}

extension URLRequest {
    /// Reads the body whether it arrived as `httpBody` or, under `URLProtocol`,
    /// as `httpBodyStream` (URLProtocol commonly delivers POST bodies as a stream).
    ///
    /// IMPORTANT: read this from INSIDE the mock handler (during `startLoading`),
    /// not after `URLSession.data(for:)` returns — by then the stream is drained.
    /// Loops until `read <= 0` (EOF/error) rather than trusting `hasBytesAvailable`,
    /// which can momentarily report false and truncate the read.
    var bodyData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while true {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
