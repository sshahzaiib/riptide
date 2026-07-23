import Foundation
import Observation
import StreamCore

struct ShowGroup: Identifiable {
    let id: String            // lowercased show title
    let title: String
    let posterPath: String?
    let episodes: [LibraryItem]
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

    var shows: [ShowGroup] {
        let episodes = filtered.filter { $0.mediaKind == "episode" }
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
        let states = (try? store.continueWatching()) ?? []
        continueWatching = states.compactMap { state in
            guard let item = items.first(where: { $0.itemKey == state.itemKey }),
                  item.mediaKind != "extra" else { return nil }
            return ContinueEntry(state: state, item: item)
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

    /// Library-priority check for addon search (movies: season/episode nil).
    func libraryItem(tmdbID: Int, season: Int?, episode: Int?) -> LibraryItem? {
        (try? store.item(tmdbID: tmdbID, season: season, episode: episode)) ?? nil
    }

    /// Any file of this TMDB title in the library (used for search-card badges).
    func hasLibraryEntry(tmdbID: Int) -> Bool {
        items.contains { $0.tmdbID == tmdbID }
    }
}
