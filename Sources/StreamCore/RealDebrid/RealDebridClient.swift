import Foundation

public struct RealDebridClient: Sendable {
    public struct Config: Sendable {
        public var baseURL: URL
        public var maxRetries: Int          // retries on 429 / rate-limit
        public var retryBaseDelay: TimeInterval
        public var pollInterval: TimeInterval
        public var pollTimeout: TimeInterval

        public init(baseURL: URL = URL(string: "https://api.real-debrid.com/rest/1.0")!,
                    maxRetries: Int = 3,
                    retryBaseDelay: TimeInterval = 1,
                    pollInterval: TimeInterval = 2,
                    pollTimeout: TimeInterval = 600) {
            self.baseURL = baseURL
            self.maxRetries = maxRetries
            self.retryBaseDelay = retryBaseDelay
            // Floor at 1ms so `elapsed` always advances in pollUntil and the pollTimeout
            // guard can fire — a 0 interval would make the timeout unreachable (unbounded poll).
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

    /// Performs one authenticated request, retrying on rate-limit up to `maxRetries`.
    /// Returns the raw 2xx body. Throws a mapped `RealDebridError` on any non-2xx.
    func send(_ method: String, _ path: String,
              query: [String: String]? = nil,
              form: [String: String]? = nil) async throws -> Data {
        var attempt = 0
        while true {
            var url = config.baseURL.appendingPathComponent(path)
            if let query, !query.isEmpty {
                var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                comps.queryItems = query.sorted { $0.key < $1.key }
                    .map { URLQueryItem(name: $0.key, value: $0.value) }
                url = comps.url!
            }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let form {
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.httpBody = Self.formEncode(form)
            }

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw RealDebridError.badResponse }
            if (200..<300).contains(http.statusCode) { return data }

            let apiError = try? JSONDecoder().decode(RealDebridAPIError.self, from: data)
            let mapped = RealDebridError.map(status: http.statusCode,
                                             apiError: apiError,
                                             retryAfter: Self.retryAfter(http))
            if case .rateLimited(let ra) = mapped, attempt < config.maxRetries {
                attempt += 1
                try await sleep(ra ?? config.retryBaseDelay * Double(attempt))
                continue
            }
            throw mapped
        }
    }

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw RealDebridError.badResponse }
    }

    /// `application/x-www-form-urlencoded` body with keys sorted for deterministic output.
    /// Percent-encodes everything outside the unreserved set, so `+` and space become `%2B`/`%20`.
    static func formEncode(_ params: [String: String]) -> Data {
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s }
        let pairs = params.sorted { $0.key < $1.key }.map { "\(enc($0.key))=\(enc($0.value))" }
        return Data(pairs.joined(separator: "&").utf8)
    }

    static func retryAfter(_ http: HTTPURLResponse) -> TimeInterval? {
        http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
    }

    // MARK: Endpoints

    public func accountInfo() async throws -> RealDebridAccount {
        try decode(RealDebridAccount.self, from: try await send("GET", "user"))
    }

    public func unrestrictLink(_ link: String) async throws -> UnrestrictedLink {
        let data = try await send("POST", "unrestrict/link", form: ["link": link])
        return try decode(UnrestrictedLink.self, from: data)
    }

    public func addMagnet(_ magnet: String) async throws -> AddMagnetResult {
        let data = try await send("POST", "torrents/addMagnet", form: ["magnet": magnet])
        return try decode(AddMagnetResult.self, from: data)
    }

    public func selectFiles(torrentID: String, files: String = "all") async throws {
        _ = try await send("POST", "torrents/selectFiles/\(torrentID)", form: ["files": files])
    }

    public func torrentInfo(_ id: String) async throws -> TorrentInfo {
        try decode(TorrentInfo.self, from: try await send("GET", "torrents/info/\(id)"))
    }

    /// One page of the user's torrent list (`GET /torrents`).
    /// RD answers 204 with an empty body when the list is empty — treat as [].
    public func listTorrents(page: Int = 1, limit: Int = 100) async throws -> [TorrentListItem] {
        let data = try await send("GET", "torrents",
                                  query: ["page": String(page), "limit": String(limit)])
        if data.isEmpty { return [] }
        return try decode([TorrentListItem].self, from: data)
    }

    /// Every torrent in the account: pages until a short page.
    public func allTorrents(limit: Int = 100) async throws -> [TorrentListItem] {
        var all: [TorrentListItem] = []
        var page = 1
        while true {
            let batch = try await listTorrents(page: page, limit: limit)
            all.append(contentsOf: batch)
            if batch.count < limit { return all }
            page += 1
        }
    }

    /// One page of previously unrestricted links (`GET /downloads`).
    public func listDownloads(page: Int = 1, limit: Int = 100) async throws -> [DownloadListItem] {
        let data = try await send("GET", "downloads",
                                  query: ["page": String(page), "limit": String(limit)])
        if data.isEmpty { return [] }
        return try decode([DownloadListItem].self, from: data)
    }

    // MARK: Magnet orchestration

    private static let failureStatuses: Set<String> = ["magnet_error", "error", "virus", "dead"]

    /// Polls `torrentInfo` until `accept` is true. Throws `.torrentFailed` on a terminal
    /// failure status and `.timedOut` once elapsed time exceeds `config.pollTimeout`.
    func pollUntil(_ id: String, accept: (TorrentInfo) -> Bool) async throws -> TorrentInfo {
        var elapsed: TimeInterval = 0
        while true {
            let info = try await torrentInfo(id)
            if Self.failureStatuses.contains(info.status) {
                throw RealDebridError.torrentFailed(status: info.status)
            }
            if accept(info) { return info }
            if elapsed >= config.pollTimeout { throw RealDebridError.timedOut }
            try await sleep(config.pollInterval)
            elapsed += config.pollInterval
        }
    }

    /// Full magnet flow: add → wait for selection → select → wait for completion →
    /// unrestrict every resulting link. Skips selection if RD already cached the torrent.
    public func resolveMagnet(_ magnet: String, fileSelection: String = "all") async throws -> [UnrestrictedLink] {
        let added = try await addMagnet(magnet)
        let beforeSelect = try await pollUntil(added.id) {
            $0.status == "waiting_files_selection" || $0.status == "downloaded"
        }
        if beforeSelect.status == "waiting_files_selection" {
            try await selectFiles(torrentID: added.id, files: fileSelection)
        }
        let done = beforeSelect.status == "downloaded"
            ? beforeSelect
            : try await pollUntil(added.id) { $0.status == "downloaded" }

        guard !done.links.isEmpty else { throw RealDebridError.noDownloadableLinks }

        // Best-effort: one bad link (infringing/unavailable) must not discard the rest
        // of a multi-file pack. Collect successes; throw only if nothing resolved.
        // ponytail: sequential keeps us under the RD rate limit and per-file failure
        // reporting is a later spec — concurrent unrestrict is a future optimization.
        var resolved: [UnrestrictedLink] = []
        var lastError: Error?
        for link in done.links {
            do { resolved.append(try await unrestrictLink(link)) }
            catch { lastError = error }
        }
        if resolved.isEmpty, let lastError { throw lastError }
        return resolved
    }
}
