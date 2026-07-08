import Foundation

/// Trakt.tv API v2 client. MainActor because tokens mutate and the app is
/// MainActor-driven; all I/O is async URLSession.
@MainActor
public final class TraktClient {
    public var tokens: TraktTokens?
    /// Fired whenever a 401-triggered refresh succeeds; the app persists them.
    public var onTokensRefreshed: ((TraktTokens) -> Void)?

    let clientID: String
    private let clientSecret: String
    private let session: URLSession
    private let base = URL(string: "https://api.trakt.tv")!

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        decoder.dateDecodingStrategy = .custom { d in
            let raw = try d.singleValueContainer().decode(String.self)
            if let date = fractional.date(from: raw) ?? plain.date(from: raw) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: d.codingPath,
                                                    debugDescription: "Bad date: \(raw)"))
        }
        return decoder
    }()

    public init(clientID: String, clientSecret: String, tokens: TraktTokens? = nil,
                session: URLSession = .shared) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.tokens = tokens
        self.session = session
    }

    // MARK: Device auth

    public func requestDeviceCode() async throws -> TraktDeviceCode {
        let data = try await post(path: "/oauth/device/code",
                                  body: ["client_id": clientID],
                                  allowedStatus: [200])
        return try Self.decoder.decode(TraktDeviceCode.self, from: data)
    }

    /// One poll step. nil = still pending (caller sleeps `interval` and retries).
    public func pollDeviceToken(deviceCode: String) async throws -> TraktTokens? {
        let (data, status) = try await postRaw(path: "/oauth/device/token",
                                               body: ["code": deviceCode,
                                                      "client_id": clientID,
                                                      "client_secret": clientSecret])
        switch status {
        case 200:
            let fetched = try Self.decoder.decode(TraktTokens.self, from: data)
            tokens = fetched
            return fetched
        case 400, 429: return nil                       // pending / slow down
        case 404, 409, 410, 418: throw TraktError.denied
        default: throw TraktError.http(status)
        }
    }

    @discardableResult
    public func refreshTokens() async throws -> TraktTokens {
        guard let tokens else { throw TraktError.unauthorized }
        let (data, status) = try await postRaw(path: "/oauth/token",
                                               body: ["refresh_token": tokens.refreshToken,
                                                      "client_id": clientID,
                                                      "client_secret": clientSecret,
                                                      "redirect_uri": "urn:ietf:wg:oauth:2.0:oob",
                                                      "grant_type": "refresh_token"])
        guard status == 200 else { throw TraktError.unauthorized }
        let fetched = try Self.decoder.decode(TraktTokens.self, from: data)
        self.tokens = fetched
        onTokensRefreshed?(fetched)
        return fetched
    }

    // MARK: Request infra

    private func request(path: String, method: String, body: Data?,
                         authorized: Bool) -> URLRequest {
        var req = URLRequest(url: base.appending(path: path))
        req.httpMethod = method
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("2", forHTTPHeaderField: "trakt-api-version")
        req.setValue(clientID, forHTTPHeaderField: "trakt-api-key")
        if authorized, let tokens {
            req.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    private func postRaw(path: String, body: [String: String]) async throws -> (Data, Int) {
        let payload = try JSONEncoder().encode(body)
        let req = request(path: path, method: "POST", body: payload, authorized: false)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw TraktError.badResponse }
        return (data, http.statusCode)
    }

    private func post(path: String, body: [String: String],
                      allowedStatus: Set<Int>) async throws -> Data {
        let (data, status) = try await postRaw(path: path, body: body)
        guard allowedStatus.contains(status) else { throw TraktError.http(status) }
        return data
    }

    /// Authorized call with a single automatic token refresh on 401.
    func send(path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        guard tokens != nil else { throw TraktError.unauthorized }
        let (data, response) = try await session.data(
            for: request(path: path, method: method, body: body, authorized: true))
        guard let http = response as? HTTPURLResponse else { throw TraktError.badResponse }
        switch http.statusCode {
        case 200, 201, 204: return data
        case 401:
            try await refreshTokens()   // throws .unauthorized on failure
            let (data2, response2) = try await session.data(
                for: request(path: path, method: method, body: body, authorized: true))
            guard let http2 = response2 as? HTTPURLResponse,
                  (200...299).contains(http2.statusCode) else {
                throw TraktError.unauthorized
            }
            return data2
        default: throw TraktError.http(http.statusCode)
        }
    }
}
