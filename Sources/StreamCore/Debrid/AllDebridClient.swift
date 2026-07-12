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

    // MARK: Diagnostics

    /// Decode failures always log (stderr) — they're rare and otherwise
    /// collapse into an opaque `badResponse`. Set RIPTIDE_AD_LOG=1 to also
    /// log every request/response.
    static let verbose = ProcessInfo.processInfo.environment["RIPTIDE_AD_LOG"] != nil

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("[AllDebrid] \(message)\n".utf8))
    }

    static func snippet(_ data: Data) -> String {
        String(data: data.prefix(600), encoding: .utf8) ?? "<non-utf8, \(data.count) bytes>"
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
            if Self.verbose {
                Self.log("POST \(path) → \(http.statusCode): \(Self.snippet(data))")
            }
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
        let env: Envelope<T>
        do {
            env = try JSONDecoder().decode(Envelope<T>.self, from: data)
        } catch {
            Self.log("decoding \(T.self) failed: \(error)\n  body: \(Self.snippet(data))")
            throw AllDebridError.badResponse
        }
        if let error = env.error { throw AllDebridError.map(error) }
        guard let payload = env.data else {
            Self.log("envelope has neither data nor error — body: \(Self.snippet(data))")
            throw AllDebridError.badResponse
        }
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

extension AllDebridClient {
    /// All magnets in the account (v4.1 list form: no links, no hash).
    public func magnetStatusList() async throws -> [ADMagnet] {
        struct Payload: Decodable { let magnets: [ADMagnet] }
        let data = try await send("v4.1/magnet/status", form: [:])
        return try decodeData(Payload.self, from: data).magnets
    }

    /// One magnet's status. AD returns data.magnets as a single object here.
    public func magnetStatus(id: Int) async throws -> ADMagnet {
        struct Payload: Decodable { let magnets: ADMagnet }
        let data = try await send("v4.1/magnet/status", form: ["id": String(id)])
        return try decodeData(Payload.self, from: data).magnets
    }

    /// Per-magnet file/link trees (batched).
    public func magnetFiles(ids: [Int]) async throws -> [ADMagnetFiles] {
        struct Payload: Decodable { let magnets: [ADMagnetFiles] }
        // AD accepts repeated id[] params; formEncode takes a dict, so send
        // one id per call when batching is unavailable. Single-id calls are
        // all plan 1 needs; plan 2 revisits batching for library sync.
        var result: [ADMagnetFiles] = []
        for id in ids {
            let data = try await send("v4/magnet/files", form: ["id[]": String(id)])
            result.append(contentsOf: try decodeData(Payload.self, from: data).magnets)
        }
        return result
    }

    public func unlock(link: String) async throws -> URL {
        struct Payload: Decodable { let link: String }
        let data = try await send("v4/link/unlock", form: ["link": link])
        let direct = try decodeData(Payload.self, from: data).link
        guard let url = URL(string: direct) ?? URL(string: direct.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") else {
            throw AllDebridError.badResponse
        }
        return url
    }

    public func magnetDelete(id: Int) async throws {
        struct Payload: Decodable { let message: String? }
        let data = try await send("v4/magnet/delete", form: ["id": String(id)])
        _ = try decodeData(Payload.self, from: data)
    }
}

/// v4.1 magnet/status entry. statusCode: 0–3 processing, 4 ready, ≥5 error.
public struct ADMagnet: Decodable, Sendable, Equatable {
    public let id: Int
    public let filename: String?
    public let size: Int64
    public let status: String?
    public let statusCode: Int
    public let downloaded: Int64
    public let uploadDate: Int?

    enum CodingKeys: String, CodingKey { case id, filename, size, status, statusCode, downloaded, uploadDate }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        filename = try c.decodeIfPresent(String.self, forKey: .filename)
        size = try c.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        status = try c.decodeIfPresent(String.self, forKey: .status)
        statusCode = try c.decode(Int.self, forKey: .statusCode)
        downloaded = try c.decodeIfPresent(Int64.self, forKey: .downloaded) ?? 0
        uploadDate = try c.decodeIfPresent(Int.self, forKey: .uploadDate)
    }
}

public struct ADMagnetFiles: Decodable, Sendable, Equatable {
    public let id: Int
    public let files: [ADFileNode]

    enum CodingKeys: String, CodingKey { case id, files }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        files = try c.decodeIfPresent([ADFileNode].self, forKey: .files) ?? []
    }
}

/// AD's file tree: {n, s, l} for files, {n, e: [children]} for folders.
public struct ADFileNode: Decodable, Sendable, Equatable {
    public let n: String
    public let s: Int64?
    public let l: String?
    public let e: [ADFileNode]?

    /// Depth-first flatten to video files, folder names joined into `path`.
    public static func flattenVideoFiles(_ nodes: [ADFileNode])
        -> [(path: String, name: String, size: Int64, link: String)] {
        var out: [(path: String, name: String, size: Int64, link: String)] = []
        func walk(_ node: ADFileNode, prefix: String) {
            if let link = node.l {
                let ext = (node.n as NSString).pathExtension.lowercased()
                guard ReleaseNameParser.videoExtensions.contains(ext) else { return }
                out.append((path: prefix + node.n, name: node.n, size: node.s ?? 0, link: link))
            } else if let children = node.e {
                for child in children { walk(child, prefix: prefix + node.n + "/") }
            }
        }
        for node in nodes { walk(node, prefix: "") }
        return out
    }
}

