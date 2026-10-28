import Foundation
import Observation
import StreamCore

struct ShowGroup: Identifiable {
    let id: String            // lowercased show title
    let title: String
    let posterPath: String?
    let episodes: [LibraryItem]

    var tmdbID: Int? { episodes.compactMap(\.tmdbID).first }
}

struct ContinueEntry: Identifiable {
    var id: String { state.itemKey }
    let state: WatchState
    let item: LibraryItem
}

@Observable
@MainActor
final class LibraryModel {
    /// One AUTH_* failure pauses AllDebrid for the session (no retry storms).
    /// AppSettings.save clears it via resetADAuth().
    static var adAuthRejected = false
    static func resetADAuth() { adAuthRejected = false }

    private(set) var items: [LibraryItem] = []
    private(set) var continueWatching: [ContinueEntry] = []
    private var allHistory: [HistoryEntry] = []
    private(set) var refreshing = false
    var searchText = ""
    var errorMessage: String?
    var needsAuth = false
    /// Lifted from LibraryRootView so the notification click handler can
    /// navigate to the Downloads section.
    var sidebarSelection: SidebarSection = .movies

    let store: LibraryStore

    init(store: LibraryStore) {
        self.store = store
        // ponytail: one-shot flag lives here so StreamCore stays UserDefaults-free.
        if !UserDefaults.standard.bool(forKey: "historyBackfilled") {
            if (try? store.backfillHistory()) != nil {
                UserDefaults.standard.set(true, forKey: "historyBackfilled")
            }
        }
        reload()
    }

    var history: [HistoryEntry] {
        guard !searchText.isEmpty else { return allHistory }
        return allHistory.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    func removeHistory(_ entry: HistoryEntry) {
        try? store.removeHistory(key: entry.key)
        reload()
    }

    private var filtered: [LibraryItem] {
        guard !searchText.isEmpty else { return items }
        let q = searchText.lowercased()
        return items.filter {
            $0.title.lowercased().contains(q) || $0.filename.lowercased().contains(q)
        }
    }

    var movies: [LibraryItem] {
        filtered.filter { $0.mediaKind == "movie" && $0.tmdbID != nil }
    }

    var shows: [ShowGroup] { Self.groupShows(filtered.filter { $0.mediaKind == "episode" }) }

    /// Unfiltered lookup for the History tab (independent of `searchText`).
    func showGroup(tmdbID: Int) -> ShowGroup? {
        Self.groupShows(items.filter { $0.mediaKind == "episode" && $0.tmdbID == tmdbID }).first
    }

    private static func groupShows(_ episodes: [LibraryItem]) -> [ShowGroup] {
        let grouped = Dictionary(grouping: episodes) { $0.title.lowercased() }
        return grouped.values.map { eps in
            let sorted = eps.sorted {
                ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0)
            }
            return ShowGroup(id: sorted[0].title.lowercased(),
                             title: sorted[0].title,
                             posterPath: sorted.compactMap(\.posterPath).first,
                             episodes: sorted)
        }
        .sorted { $0.title < $1.title }
    }

    var unmatched: [LibraryItem] {
        filtered.filter { $0.tmdbID == nil && $0.mediaKind == "movie" }
    }

    func reload() {
        items = (try? store.items()) ?? []
        allHistory = (try? store.history()) ?? []
        let states = (try? store.continueWatching()) ?? []
        let entries: [ContinueEntry] = states.compactMap { state in
            guard let item = items.first(where: { $0.itemKey == state.itemKey }),
                  item.mediaKind != "extra" else { return nil }
            return ContinueEntry(state: state, item: item)
        }
        // Duplicate copies (same tmdbID/season/episode) collapse to the newest.
        func dupKey(_ e: ContinueEntry) -> String {
            e.item.tmdbID.map { "\($0)/\(e.item.season ?? -1)/\(e.item.episode ?? -1)" } ?? e.item.itemKey
        }
        let newest = Dictionary(entries.map { (dupKey($0), $0) }) {
            $0.state.lastWatchedAt >= $1.state.lastWatchedAt ? $0 : $1
        }
        var seen = Set<String>()
        continueWatching = entries.compactMap { e in
            let k = dupKey(e)
            return seen.insert(k).inserted ? newest[k] : nil
        }
    }

    /// Items awaiting the "Ask before deleting" confirmation (one dialog on the root view).
    var pendingDelete: [LibraryItem]?

    func requestDelete(_ items: [LibraryItem]) {
        if UserDefaults.standard.object(forKey: "confirmDelete") as? Bool ?? true {
            pendingDelete = items
        } else {
            Task { for item in items { await delete(item) } }
        }
    }

    /// Deletes the item's whole torrent from the debrid account, then locally.
    func delete(_ item: LibraryItem) async {
        // Multi-version selections can share a torrent; it's already gone then.
        guard items.contains(where: { $0.itemKey == item.itemKey }) else { return }
        let settings = AppSettings.shared
        let service: any DebridService = item.service == "ad"
            ? AllDebridService(client: AllDebridClient(token: settings.adToken))
            : RealDebridService(rd: RealDebridClient(token: settings.rdToken))
        do {
            try await service.delete(id: item.torrentID)
            try store.delete(torrentID: item.torrentID)
            reload()
        } catch {
            errorMessage = "Delete failed: \(error)"
        }
    }

    func refresh() async {
        guard !refreshing else { return }
        let settings = AppSettings.shared
        guard settings.isConfigured else { needsAuth = true; return }
        refreshing = true
        defer { refreshing = false; reload() }
        do {
            var services: [any DebridService] =
                [RealDebridService(rd: RealDebridClient(token: settings.rdToken))]
            let adTokenUsed = settings.adToken
            if !adTokenUsed.isEmpty, !Self.adAuthRejected {
                services.append(AllDebridService(client: AllDebridClient(token: adTokenUsed)))
            }
            let refresher = LibraryRefresher(services: services,
                                             tmdb: TMDBClient(bearerToken: settings.tmdbToken, cache: .shared),
                                             store: store)
            let summary = try await refresher.refresh()
            await TraktService.shared.pullSync(store: store)
            if summary.authFailures.contains("rd") { needsAuth = true }
            if summary.authFailures.contains("ad"),
               AppSettings.shared.adToken == adTokenUsed {
                // No retry storms: one AUTH_* failure pauses AD until relaunch
                // or a new key is saved. A key saved while this refresh was in
                // flight must not be re-paused by the OLD key's failure.
                Self.adAuthRejected = true
                errorMessage = "AllDebrid rejected your API key — check Settings. AllDebrid is paused until you save a new key."
            } else if let firstError = summary.serviceErrors.values.first {
                errorMessage = "Partial refresh: \(firstError)"
            } else {
                errorMessage = summary.matchFailed > 0
                    ? "\(summary.matchFailed) item(s) could not be matched on TMDB." : nil
            }
        } catch let e as RealDebridError where e == .unauthorized {
            needsAuth = true
        } catch {
            errorMessage = "Refresh failed: \(error)"
        }
    }

    /// Unrestrict this file's link and build its PlayItem.
    func playItem(for item: LibraryItem, autoResume: Bool = false) async throws -> PlayItem {
        try await PlayItemBuilder.make(for: item, store: store, autoResume: autoResume)
    }

    /// First library item belonging to a torrent (itemKeys are "torrentID#fileIndex").
    func firstItem(torrentID: String) -> LibraryItem? {
        items.first { $0.torrentID == torrentID }
    }

    /// Observed in-memory lookup for view bodies: registers a SwiftUI
    /// dependency on `items` and avoids a store fetch per card.
    func observedLibraryItem(tmdbID: Int, season: Int?, episode: Int?) -> LibraryItem? {
        items.first { $0.tmdbID == tmdbID && $0.season == season && $0.episode == episode }
    }

    /// Library-priority check for addon search (movies: season/episode nil).
    func libraryItem(tmdbID: Int, season: Int?, episode: Int?) -> LibraryItem? {
        (try? store.item(tmdbID: tmdbID, season: season, episode: episode)) ?? nil
    }

    /// Any file of this TMDB title in the library (used for search-card badges).
    func hasLibraryEntry(tmdbID: Int) -> Bool {
        items.contains { $0.tmdbID == tmdbID }
    }

    func hasLibraryEntry(tmdbID: Int, isShow: Bool) -> Bool {
        items.contains { item in
            item.tmdbID == tmdbID && (isShow ? item.mediaKind == "episode" : item.mediaKind == "movie")
        }
    }
}

