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

    /// Uncached selection: fetching one byte makes the addon's resolver
    /// register the torrent with the debrid service; no playback.
    nonisolated func registerUncached(url: URL) {
        Task.detached {
            var request = URLRequest(url: url)
            request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            request.timeoutInterval = 30
            // bytes(for:) + cancel stays bounded even when the resolver's
            // redirect target ignores Range — data(for:) would buffer the
            // whole (multi-GB) file into memory.
            guard let (bytes, _) = try? await URLSession.shared.bytes(for: request)
            else { return }
            var iterator = bytes.makeAsyncIterator()
            _ = try? await iterator.next()
            bytes.task.cancel()
        }
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
