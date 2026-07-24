import Foundation
import Observation
import StreamCore

/// Single source of truth for Trakt watchlist state in the UI. Trakt owns
/// the list; this is a session mirror with optimistic add/remove.
@Observable @MainActor
final class WatchlistModel {
    static let shared = WatchlistModel()

    enum State { case idle, loading, loaded, failed }

    private(set) var items: [SearchMedia] = []
    private(set) var state: State = .idle
    /// Membership keyed by SearchMedia.id ("movie-603" / "show-1396").
    private(set) var membership: Set<String> = []
    /// Transient message from the last failed toggle; cleared on next toggle.
    private(set) var lastError: (id: String, message: String)?

    private var inFlight: Task<Void, Never>?
    private var mutationCount = 0
    private var toggling: Set<String> = []

    func isOnWatchlist(_ media: SearchMedia) -> Bool {
        membership.contains(media.id)
    }

    func isToggling(_ media: SearchMedia) -> Bool {
        toggling.contains(media.id)
    }

    /// Fetches the watchlist fresh (never cached) and resolves posters.
    /// Single-flight: concurrent callers await the same fetch. An already-
    /// loaded list keeps rendering while it silently revalidates.
    func load() async {
        if let inFlight { await inFlight.value; return }
        let task = Task { await self.doLoad() }
        inFlight = task
        await task.value
        inFlight = nil
    }

    private func doLoad() async {
        guard let trakt = TraktService.shared.client else {
            items = []; membership = []; state = .idle
            return
        }
        let wasLoaded = state == .loaded
        if !wasLoaded { state = .loading }
        do {
            let epoch = mutationCount
            let entries = try await trakt.watchlist()
            let resolved = await resolveTraktRows(entries.map {
                (isShow: $0.type == "show", media: $0.show ?? $0.movie)
            })
            guard epoch == mutationCount else {
                if !wasLoaded { state = .idle }
                return
            }
            items = resolved
            membership = Set(resolved.map(\.id))
            state = .loaded
        } catch {
            // Keep showing a populated list on a failed silent refresh.
            if !wasLoaded { state = .failed }
        }
    }

    /// Optimistic add/remove; reverts and sets lastError on API failure.
    func toggle(_ media: SearchMedia) async {
        guard let trakt = TraktService.shared.client else { return }
        guard !toggling.contains(media.id) else { return }
        toggling.insert(media.id)
        defer { toggling.remove(media.id) }

        mutationCount += 1
        lastError = nil
        let wasOn = membership.contains(media.id)
        if wasOn {
            membership.remove(media.id)
            items.removeAll { $0.id == media.id }
        } else {
            membership.insert(media.id)
            items.insert(media, at: 0)   // Trakt lists newest first
        }
        do {
            if wasOn {
                try await trakt.removeFromWatchlist(tmdbID: media.tmdbID, isShow: media.isShow)
            } else {
                try await trakt.addToWatchlist(tmdbID: media.tmdbID, isShow: media.isShow)
            }
        } catch {
            // Revert the flip.
            if wasOn {
                membership.insert(media.id)
                if !items.contains(where: { $0.id == media.id }) {
                    items.insert(media, at: 0)
                }
            } else {
                membership.remove(media.id)
                items.removeAll { $0.id == media.id }
            }
            lastError = (media.id, wasOn ? "Couldn't remove from watchlist"
                                         : "Couldn't add to watchlist")
        }
    }
}
