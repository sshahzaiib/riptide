import Foundation

/// AllDebrid v4 API client. Same shape as RealDebridClient: Sendable struct,
/// injectable session + sleep, typed errors. AD quirk: every endpoint is a
/// POST with form params, responses wrap payloads in {status, data|error},
/// and per-magnet failures arrive INSIDE a success envelope.
public struct AllDebridClient: Sendable {
    public struct Config: Sendable {
        public var baseURL: URL
        public var maxRetries: Int
        public var retryBaseDelay: TimeInterval
        public var pollInterval: TimeInterval
        public var pollTimeout: TimeInterval

        public init(baseURL: URL = URL(string: "https://api.alldebrid.com")!,
                    maxRetries: Int = 3,
                    retryBaseDelay: TimeInterval = 1,
                    pollInterval: TimeInterval = 2,
                    pollTimeout: TimeInterval = 600) {
            self.baseURL = baseURL
            self.maxRetries = maxRetries
            self.retryBaseDelay = retryBaseDelay
            self.pollInterval = max(0.001, pollInterval)
            self.pollTimeout = pollTimeout
        }
    }

    let token: String
    let session: URLSession
    let config: Config
    let sleep: @Sendable (TimeInterval) async throws -> Void

    public init(token: String,
                session: URLSession = .shared,
                config: Config = Config(),
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
                    try await Task.sleep(for: .seconds(max(0, $0)))
                }) {
        self.token = token
        self.session = session
        self.config = config
        self.sleep = sleep
    }

    // MARK: Request layer

    /// POST with form params; retries 429/503 up to maxRetries. Returns the
    /// raw body of the enveloped response (caller decodes via decodeData).
    func send(_ path: String, form: [String: String]) async throws -> Data {
        var attempt = 0
        while true {
            var request = URLRequest(url: config.baseURL.appendingPathComponent(path))
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/x-www-form-urlencoded",
                             forHTTPHeaderField: "Content-Type")
            request.httpBody = RealDebridClient.formEncode(form)

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw AllDebridError.badResponse }
            if http.statusCode == 429 || http.statusCode == 503 {
                guard attempt < config.maxRetries else { throw AllDebridError.rateLimited }
                attempt += 1
                try await sleep(config.retryBaseDelay * Double(attempt))
                continue
            }
            guard (200..<300).contains(http.statusCode) else {
                throw AllDebridError.http(http.statusCode)
            }
            return data
        }
    }

    private struct Envelope<D: Decodable>: Decodable {
        let status: String
        let data: D?
        let error: ADAPIError?
    }

    /// Unwraps the {status, data|error} envelope and decodes `data`.
    func decodeData<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard let env = try? JSONDecoder().decode(Envelope<T>.self, from: data)
        else { throw AllDebridError.badResponse }
        if let error = env.error { throw AllDebridError.map(error) }
        guard let payload = env.data else { throw AllDebridError.badResponse }
        return payload
    }

    // MARK: Endpoints

    public func magnetUpload(_ magnet: String) async throws -> ADMagnetUpload {
        struct Payload: Decodable { let magnets: [ADMagnetUpload] }
        let data = try await send("v4/magnet/upload", form: ["magnets[]": magnet])
        let payload = try decodeData(Payload.self, from: data)
        guard let first = payload.magnets.first else { throw AllDebridError.badResponse }
        if let error = first.error { throw AllDebridError.map(error) }
        guard let id = first.id else { throw AllDebridError.badResponse }
        return ADMagnetUpload(id: id, ready: first.ready ?? false, hash: first.hash,
                               name: first.name, size: first.size, error: nil)
    }
}

/// One element of magnet/upload's data.magnets. All fields optional because
/// a rejected magnet carries only {magnet, error}.
public struct ADMagnetUpload: Decodable, Sendable, Equatable {
    public let id: Int?
    public let ready: Bool?
    public let hash: String?
    public let name: String?
    public let size: Int64?
    let error: ADAPIError?

    init(id: Int?, ready: Bool?, hash: String?, name: String?, size: Int64?,
         error: ADAPIError?) {
        self.id = id; self.ready = ready; self.hash = hash
        self.name = name; self.size = size; self.error = error
    }
}

struct ADAPIError: Decodable, Sendable, Equatable {
    let code: String
    let message: String?
}

public enum AllDebridError: Error, Equatable, Sendable {
    case authFailed
    case magnetRejected(code: String)
    case rateLimited
    case http(Int)
    case badResponse

    static func map(_ apiError: ADAPIError) -> AllDebridError {
        apiError.code.hasPrefix("AUTH_") ? .authFailed
            : .magnetRejected(code: apiError.code)
    }
}
