import Foundation
import StreamCore

extension URLSession {
    /// Session for addon requests (stream queries, add-time validation) —
    /// 10 s per-request timeout: long enough for a self-hosted addon's cold
    /// live scrape (~6 s observed), short enough that one dead addon can't
    /// stall the list or hang the Settings validation spinner.
    static let addon: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()
}

@Observable
@MainActor
final class StreamPickerModel {
    struct Row: Identifiable {
        let id = UUID()
        let addon: ConfiguredAddon
        let stream: AddonStream
        let meta: ParsedStreamMeta

        var intendedService: DebridServiceID { meta.service ?? addon.service ?? .realDebrid }
    }

    private(set) var rows: [Row] = []
    private(set) var loadingCount = 0       // addons still in flight
    private(set) var failedAddons: [String] = []
    var filterAddonID: UUID?
    /// Addon order as of the current load — every row's addon is in it.
    private var addonOrder: [UUID] = []

    var visibleRows: [Row] {
        guard let filterAddonID else { return rows }
        return rows.filter { $0.addon.id == filterAddonID }
    }

    /// visibleRows grouped per addon, in the user's addon order (rows are
    /// already sorted that way, so this only chunks consecutive runs).
    var sections: [(addon: ConfiguredAddon, rows: [Row])] {
        visibleRows.reduce(into: []) { out, row in
            if out.last?.addon.id == row.addon.id { out[out.count - 1].rows.append(row) }
            else { out.append((row.addon, [row])) }
        }
    }

    func load(_ request: StreamRequest) async {
        rows = []
        failedAddons = []
        let addons = AppSettings.shared.addons
        addonOrder = addons.map(\.id)
        loadingCount = addons.count
        let client = StremioAddonClient(session: .addon)

        await withTaskGroup(of: (ConfiguredAddon, [AddonStream]?).self) { group in
            for addon in addons {
                group.addTask {
                    let streams = try? await client.streams(baseURL: addon.url,
                                                            type: request.type,
                                                            imdbID: request.imdbID,
                                                            season: request.season,
                                                            episode: request.episode)
                    return (addon, streams)
                }
            }
            // Results render incrementally as each addon answers.
            for await (addon, streams) in group {
                loadingCount -= 1
                guard let streams else {
                    failedAddons.append(addon.name)
                    continue
                }
                rows.append(contentsOf: streams.compactMap { stream in
                    // debrid-resolved media only: no P2P results, no addon actions
                    guard stream.httpURL != nil, !stream.isAction else { return nil }
                    return Row(addon: addon, stream: stream,
                               meta: StreamResultParser.parse(stream))
                })
                sortRows()
            }
        }
    }

    enum UncachedOutcome {
        case added(service: DebridServiceID, transferID: String)  // pollable → auto-play
        case probed                                               // registered blind
        case failed(bothTried: Bool)   // true when the router attempted both services
    }

    /// RD download progress (0–100) for an uncached pick, nil when idle.
    private(set) var downloadProgress: Double?

    /// Router over the services the user has tokens for.
    private var router: DebridRouter {
        let settings = AppSettings.shared
        return DebridRouter(
            rd: settings.rdToken.isEmpty ? nil
                : RealDebridService(rd: RealDebridClient(token: settings.rdToken)),
            ad: settings.adToken.isEmpty ? nil
                : AllDebridService(client: AllDebridClient(token: settings.adToken)))
    }

    /// Uncached selection: register the torrent on the service the pick's
    /// addon is configured for (nil/undetected → RD), failing over once to
    /// the other service on terminal rejection. Hash recovery first; the
    /// account-diff fallback covers opaque resolver URLs (no failover there —
    /// nothing to re-add).
    func registerUncached(row: Row) async -> UncachedOutcome {
        guard let url = row.stream.httpURL else { return .failed(bothTried: false) }
        let router = router
        if let hash = row.stream.infoHash ?? TorrentAdder.infohash(inURL: url) {
            // The hash path fails over, so a failure here means every
            // configured service was tried.
            let settings = AppSettings.shared
            let bothTried = !settings.rdToken.isEmpty && !settings.adToken.isEmpty
            do {
                let placed = try await router.addWithFailover(
                    magnet: "magnet:?xt=urn:btih:\(hash)",
                    preferring: row.intendedService)
                if case .failed = placed.transfer.status { return .failed(bothTried: bothTried) }
                return .added(service: placed.serviceID, transferID: placed.transfer.id)
            } catch { return .failed(bothTried: bothTried) }
        }
        // Opaque resolver URL: probe, then find the new transfer by diffing
        // the TARGET service's account. No failover here — nothing to re-add.
        guard let target = router.service(row.intendedService)
        else { return .failed(bothTried: false) }
        // No snapshot -> no reliable diff: an empty `before` would make every
        // pre-existing transfer look new and lock onto the wrong one. Register
        // blind instead.
        guard let before = try? await target.transferIDs() else {
            return await probeResolver(url: url) ? .probed : .failed(bothTried: false)
        }
        guard await probeResolver(url: url) else { return .failed(bothTried: false) }
        for attempt in 0..<6 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(3)) }
            if Task.isCancelled { break }
            guard let now = try? await target.transferIDs() else { continue }
            if let new = now.subtracting(before).first {
                try? await target.finishForeignAdd(id: new)
                return .added(service: target.serviceID, transferID: new)
            }
        }
        return .probed   // resolver answered but no new transfer surfaced
    }

    /// Polls the service until the transfer finishes (then the resolver URL
    /// streams like any cached pick). Publishes progress for the sheet.
    func waitUntilDownloaded(service: DebridServiceID, transferID: String) async -> Bool {
        guard let service = router.service(service) else { return false }
        downloadProgress = 0
        defer { downloadProgress = nil }
        var consecutiveFailures = 0
        while !Task.isCancelled {
            do {
                let transfer = try await service.transferStatus(id: transferID)
                consecutiveFailures = 0
                switch transfer.status {
                case .ready: return true
                case .failed: return false
                case .processing(let progress): downloadProgress = progress
                }
            } catch {
                consecutiveFailures += 1
                if consecutiveFailures >= 5 { return false }
            }
            try? await Task.sleep(for: .seconds(3))
        }
        return false
    }

    /// Fallback when no infohash is recoverable: fetching one byte makes the
    /// addon's resolver register the torrent with the debrid service.
    private nonisolated func probeResolver(url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.timeoutInterval = 30
        // bytes(for:) + cancel stays bounded even when the resolver's
        // redirect target ignores Range — data(for:) would buffer the
        // whole (multi-GB) file into memory.
        guard let (bytes, response) = try? await URLSession.shared.bytes(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return false }
        var iterator = bytes.makeAsyncIterator()
        _ = try? await iterator.next()
        bytes.task.cancel()
        return true
    }

    /// Addon order first (the first addon in Settings wins; later ones are
    /// the fallback), then cached / resolution / size within each addon.
    private func sortRows() {
        func key(_ row: Row) -> (Int, Int, Int, Int64) {
            row.meta.sortKey(addonIndex: addonOrder.firstIndex(of: row.addon.id) ?? .max)
        }
        rows.sort { a, b in
            if key(a) != key(b) { return key(a) < key(b) }
            // Stable final tie-break so incremental addon results don't
            // visibly shuffle equal-ranked rows while loading.
            return (a.stream.url ?? a.stream.displayText)
                 < (b.stream.url ?? b.stream.displayText)
        }
    }
}
