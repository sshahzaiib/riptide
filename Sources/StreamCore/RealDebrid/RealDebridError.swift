import Foundation

public enum RealDebridError: Error, Equatable, Sendable {
    case unauthorized                            // bad/expired token (error_code 8, HTTP 401/403)
    case rateLimited(retryAfter: TimeInterval?)  // HTTP 429 or error_code 5/34
    case infringingFile                          // error_code 35
    case hosterUnavailable(code: Int)            // error_code 16...20
    case torrentFailed(status: String)           // poll saw a terminal failure status
    case noDownloadableLinks                     // a completed torrent yielded no usable links
    case timedOut                                // poll exceeded the configured timeout
    case api(code: Int, message: String)         // any other documented error_code
    case http(status: Int)                       // non-2xx with no decodable RD body
    case badResponse                             // not an HTTP response, or body failed to decode

    /// Classify a non-2xx response. An RD error body's `error_code` takes precedence;
    /// otherwise fall back to the HTTP status.
    static func map(status: Int, apiError: RealDebridAPIError?, retryAfter: TimeInterval?) -> RealDebridError {
        if let code = apiError?.errorCode {
            switch code {
            case 8:        return .unauthorized
            case 5, 34:    return .rateLimited(retryAfter: retryAfter)
            case 35:       return .infringingFile
            case 16...20:  return .hosterUnavailable(code: code)
            default:       return .api(code: code, message: apiError?.errorDetails ?? apiError?.error ?? "")
            }
        }
        switch status {
        case 401, 403: return .unauthorized
        case 429:      return .rateLimited(retryAfter: retryAfter)
        default:       return .http(status: status)
        }
    }
}

/// Without this, UI that shows `error.localizedDescription` prints
/// "The operation couldn't be completed. (StreamCore.RealDebridError error 6.)".
extension RealDebridError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unauthorized: "Real-Debrid rejected the token. Check it in Settings."
        case .rateLimited: "Real-Debrid is rate limiting requests. Try again in a moment."
        case .infringingFile: "Real-Debrid has blocked this file. Try another version."
        case .hosterUnavailable(let code): "The file host is unavailable right now (Real-Debrid code \(code))."
        case .torrentFailed(let status): "Real-Debrid couldn't prepare this torrent (\(status))."
        case .noDownloadableLinks: "Real-Debrid returned no playable links for this file."
        case .timedOut: "Real-Debrid took too long to respond. Try again."
        case .api(let code, let message): message.isEmpty ? "Real-Debrid error \(code)." : "Real-Debrid: \(message) (code \(code))."
        case .http(let status): "Real-Debrid returned HTTP \(status)."
        case .badResponse: "Real-Debrid sent a response Riptide couldn't read."
        }
    }
}
