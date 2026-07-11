import Foundation
import StreamCore

extension URLSession {
    /// Session for addon requests (stream queries, add-time validation) —
    /// 5 s per-request timeout so one slow/dead addon can't stall the merged
    /// list or hang the Settings validation spinner.
    static let addon: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
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
    }

    private(set) var rows: [Row] = []
    private(set) var loadingCount = 0       // addons still in flight
    private(set) var failedAddons: [String] = []
    var filterAddonID: UUID?

    var visibleRows: [Row] {
        guard let filterAddonID else { return rows }
        return rows.filter { $0.addon.id == filterAddonID }
    }

    func load(_ request: StreamRequest) async {
        rows = []
        failedAddons = []
        let addons = AppSettings.shared.addons
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
                    guard stream.httpURL != nil else { return nil }   // debrid-resolved only
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
        case failed
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
    func registerUncached(stream: AddonStream, addon: ConfiguredAddon) async -> UncachedOutcome {
        guard let url = stream.httpURL else { return .failed }
        let router = router
        if let hash = stream.infoHash ?? TorrentAdder.infohash(inURL: url) {
            do {
                let placed = try await router.addWithFailover(
                    magnet: "magnet:?xt=urn:btih:\(hash)",
                    preferring: addon.service)
                if case .failed = placed.transfer.status { return .failed }
                return .added(service: placed.serviceID, transferID: placed.transfer.id)
            } catch { return .failed }
        }
        // Opaque resolver URL: probe, then find the new transfer by diffing
        // the TARGET service's account.
        guard let target = router.service(addon.service ?? .realDebrid) else { return .failed }
        let before = (try? await target.transferIDs()) ?? []
        guard await probeResolver(url: url) else { return .failed }
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

    private func sortRows() {
        let addonOrder = AppSettings.shared.addons.map(\.id)
        func cachedRank(_ cached: Bool?) -> Int {
            switch cached { case .some(true): 0; case .none: 1; case .some(false): 2 }
        }
        func resolutionRank(_ resolution: String?) -> Int {
            switch resolution {
            case "2160p"?: 0; case "1080p"?: 1; case "720p"?: 2; case "480p"?: 3; default: 4
            }
        }
        rows.sort { a, b in
            if cachedRank(a.meta.cached) != cachedRank(b.meta.cached) {
                return cachedRank(a.meta.cached) < cachedRank(b.meta.cached)
            }
            if resolutionRank(a.meta.resolution) != resolutionRank(b.meta.resolution) {
                return resolutionRank(a.meta.resolution) < resolutionRank(b.meta.resolution)
            }
            if (a.meta.sizeBytes ?? 0) != (b.meta.sizeBytes ?? 0) {
                return (a.meta.sizeBytes ?? 0) > (b.meta.sizeBytes ?? 0)
            }
            if a.addon.id != b.addon.id {
                return (addonOrder.firstIndex(of: a.addon.id) ?? .max)
                     < (addonOrder.firstIndex(of: b.addon.id) ?? .max)
            }
            // Stable final tie-break so incremental addon results don't
            // visibly shuffle equal-ranked rows while loading.
            return (a.stream.url ?? a.stream.displayText)
                 < (b.stream.url ?? b.stream.displayText)
        }
    }
}
