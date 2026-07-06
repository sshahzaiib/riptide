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
    private(set) var items: [LibraryItem] = []
    private(set) var continueWatching: [ContinueEntry] = []
    private(set) var refreshing = false
    var searchText = ""
    var errorMessage: String?
    var needsAuth = false

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
            let torrentID = String(state.itemKey.split(separator: "#")[0])
            guard let item = items.first(where: { $0.torrentID == torrentID }) else { return nil }
            return ContinueEntry(state: state, item: item)
        }
    }

    func refresh() async {
        let settings = AppSettings.shared
        guard settings.isConfigured else { needsAuth = true; return }
        refreshing = true
        defer { refreshing = false; reload() }
        do {
            let refresher = LibraryRefresher(
                rd: RealDebridClient(token: settings.rdToken),
                tmdb: TMDBClient(bearerToken: settings.tmdbToken),
                store: store)
            let summary = try await refresher.refresh()
            errorMessage = summary.matchFailed > 0
                ? "\(summary.matchFailed) item(s) could not be matched on TMDB." : nil
        } catch let e as RealDebridError where e == .unauthorized {
            needsAuth = true
        } catch {
            errorMessage = "Refresh failed: \(error)"
        }
    }

    /// Unrestrict and build the PlayItem for one file of a library item.
    func playItem(for item: LibraryItem, fileIndex: Int) async throws -> PlayItem {
        let settings = AppSettings.shared
        let rd = RealDebridClient(token: settings.rdToken)
        let link = item.links[fileIndex]
        let unrestricted = try await rd.unrestrictLink(link)
        guard let url = unrestricted.directURL else { throw RealDebridError.badResponse }
        let itemKey = "\(item.torrentID)#\(fileIndex)"
        let resume = (try? store.continueWatching())?
            .first { $0.itemKey == itemKey }?.positionSeconds
        return PlayItem(itemKey: itemKey,
                        title: item.title,
                        url: url,
                        resumeFrom: resume,
                        subtitleQuery: item.title,
                        season: item.season,
                        episode: item.episode)
    }
}
