import Foundation

public struct PairingRequest: Equatable, Sendable {
    public let method: String
    public let path: String
    public let contentType: String?
    public let body: String

    public init(method: String, path: String, contentType: String?, body: String) {
        self.method = method
        self.path = path
        self.contentType = contentType
        self.body = body
    }
}

/// Just enough HTTP/1.1 for the one-page pairing form.
public enum PairingHTTP {
    /// Returns nil until the full `Content-Length` body has arrived, or when
    /// the request is malformed / not UTF-8.
    public static func parse(_ raw: Data) -> PairingRequest? {
        guard let split = raw.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: raw[..<split.lowerBound], encoding: .utf8)
        else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        guard start.count >= 2 else { return nil }
        var length = 0
        var badLength = false
        var contentType: String?
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "content-length" {
                if let n = Int(value), n >= 0 { length = n } else { badLength = true }
            }
            if name == "content-type" { contentType = value }
        }
        let bodyData = raw[split.upperBound...]
        guard !badLength, bodyData.count >= length,
              let body = String(data: bodyData.prefix(length), encoding: .utf8)
        else { return nil }
        return PairingRequest(method: String(start[0]), path: String(start[1]),
                              contentType: contentType, body: body)
    }

    public static func response(status: Int, html: String) -> Data {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        default: reason = "Error"
        }
        let body = Data(html.utf8)
        var out = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        out.append(body)
        return out
    }
}
