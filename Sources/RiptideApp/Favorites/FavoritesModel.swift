import Foundation
import Observation
import StreamCore

/// Session mirror of Trakt favorites membership with optimistic toggles.
/// Membership-only: nothing in the app displays a favorites list, favorites
/// exist to feed Trakt's recommendation engine.
@Observable @MainActor
final class FavoritesModel {
    static let shared = FavoritesModel()

    enum State { case idle, loading, loaded, failed }

    private(set) var state: State = .idle
    /// Membership keyed by SearchMedia.id ("movie-603" / "show-1396").
    private(set) var membership: Set<String> = []
    /// Transient message from the last failed toggle; cleared on next toggle.
    private(set) var lastError: (id: String, message: String)?

    private var inFlight: Task<Void, Never>?
    private var mutationCount = 0
    private var toggling: Set<String> = []

    func isFavorite(_ media: SearchMedia) -> Bool {
        membership.contains(media.id)
    }

    func isToggling(_ media: SearchMedia) -> Bool {
        toggling.contains(media.id)
    }

    /// Called by TraktService on disconnect so a reconnect doesn't show the
    /// previous account's favorites.
    func reset() {
        membership = []
        state = .idle
        lastError = nil
        ShelfDiskCache.remove(name: "favorites")
    }

    /// Single-flight fetch; concurrent callers await the same request.
    func load() async {
        if let inFlight { await inFlight.value; return }
        let task = Task { await self.doLoad() }
        inFlight = task
        await task.value
        inFlight = nil
    }

    private func doLoad() async {
        guard let trakt = TraktService.shared.client else {
            membership = []; state = .idle
            return
        }
        if state == .idle,
           let cached = ShelfDiskCache.load(Set<String>.self, name: "favorites") {
            membership = cached
            state = .loaded
        }
        let wasLoaded = state == .loaded
        if !wasLoaded { state = .loading }
        do {
            let epoch = mutationCount
            let entries = try await trakt.favorites()
            guard epoch == mutationCount else {
                // A toggle landed mid-fetch; snapshot is stale. Refetch rather
                // than discard (same guard WatchlistModel uses).
                return await doLoad()
            }
            membership = Set(entries.compactMap { entry in
                let isShow = entry.type == "show"
                guard let tmdb = (isShow ? entry.show : entry.movie)?.ids.tmdb else { return nil }
                return (isShow ? "show-" : "movie-") + String(tmdb)
            })
            state = .loaded
            ShelfDiskCache.save(membership, name: "favorites")
        } catch {
            if !wasLoaded { state = .failed }
        }
    }

    /// Optimistic flip; reverts and sets lastError on API failure.
    func toggle(_ media: SearchMedia) async {
        guard let trakt = TraktService.shared.client else { return }
        guard !toggling.contains(media.id) else { return }
        toggling.insert(media.id)
        defer {
            toggling.remove(media.id)
            // Invalidate any in-flight load() started while this toggle was
            // executing, preventing a stale fetched snapshot from overwriting
            // this mutation's result.
            mutationCount += 1
        }

        mutationCount += 1
        lastError = nil
        let wasOn = membership.contains(media.id)
        if wasOn { membership.remove(media.id) } else { membership.insert(media.id) }
        do {
            if wasOn {
                try await trakt.removeFromFavorites(tmdbID: media.tmdbID, isShow: media.isShow)
            } else {
                try await trakt.addToFavorites(tmdbID: media.tmdbID, isShow: media.isShow)
            }
        } catch {
            if wasOn { membership.insert(media.id) } else { membership.remove(media.id) }
            lastError = (media.id, wasOn ? "Couldn't remove from favorites"
                                         : "Couldn't add to favorites")
        }
    }
}
