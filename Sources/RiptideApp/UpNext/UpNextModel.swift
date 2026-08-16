import Foundation
import Observation
import StreamCore

/// Trakt-wide continue watching: paused playback plus the next unwatched
/// episode of recently watched shows (incl. history synced from Netflix
/// etc.). Read-only mirror — nothing in the app mutates it, so no epoch
/// machinery is needed.
@Observable @MainActor
final class UpNextModel {
    static let shared = UpNextModel()

    enum State { case idle, loading, loaded, failed }

    struct Entry: Identifiable {
        let media: SearchMedia
        let item: UpNextItem
        var id: String { media.id }
        var subtitle: String {
            if let s = item.season, let n = item.number {
                let marker = "S\(s) E\(n)"
                if let pct = item.progressPercent { return "\(marker) · \(Int(pct))%" }
                if let title = item.episodeTitle, !title.isEmpty { return "\(marker) · \(title)" }
                return marker
            }
            if let pct = item.progressPercent { return "\(Int(pct))% watched" }
            return ""
        }
    }

    private(set) var entries: [Entry] = []
    private(set) var state: State = .idle

    private var inFlight: Task<Void, Never>?

    func entry(for media: SearchMedia) -> Entry? {
        entries.first { $0.media.id == media.id }
    }

    /// Single-flight; a loaded rail keeps rendering while it revalidates.
    func load() async {
        if let inFlight { await inFlight.value; return }
        let task = Task { await self.doLoad() }
        inFlight = task
        await task.value
        inFlight = nil
    }

    private func doLoad() async {
        guard let trakt = TraktService.shared.client else {
            entries = []; state = .idle
            return
        }
        let wasLoaded = state == .loaded
        if !wasLoaded { state = .loading }
        do {
            async let watchedFetch = trakt.watchedShows()
            async let playbackFetch = trakt.playback()
            // Hiding is cosmetic — a failed hidden fetch degrades to no filtering.
            let hidden = (try? await trakt.hiddenProgressShows()) ?? []
            let watched = try await watchedFetch
            let playback = try await playbackFetch

            let hiddenIDs = Set(hidden.compactMap { $0.show?.ids.tmdb })
            let shortlist = UpNextBuilder.shortlist(watched: watched, hiddenTMDBIDs: hiddenIDs)
            let progress = await fetchProgress(for: shortlist, client: trakt)
            let items = UpNextBuilder.build(playback: playback, progressByShow: progress)

            // resolveTMDBCards is 1:1 and order-preserving, so zip is safe.
            let cards = await resolveTMDBCards(items.map { (isShow: $0.isShow, id: $0.tmdbID,
                                                            title: "", year: nil as Int?) })
            entries = zip(cards, items).map { Entry(media: $0, item: $1) }
            state = .loaded
        } catch {
            if !wasLoaded { state = .failed }
        }
    }

    /// One progress call per shortlisted show; a failed call drops that
    /// show only. Order follows the shortlist (newest first).
    private func fetchProgress(for shows: [TraktWatchedShow],
                               client: TraktClient) async
        -> [(show: TraktWatchedShow, progress: TraktShowProgress)] {
        var indexed: [(Int, TraktShowProgress)] = []
        await withTaskGroup(of: (Int, TraktShowProgress?).self) { group in
            for (index, show) in shows.enumerated() {
                guard let traktID = show.show.ids.trakt else { continue }
                group.addTask { @MainActor in
                    (index, try? await client.showProgress(traktID: traktID))
                }
            }
            for await (index, progress) in group {
                if let progress { indexed.append((index, progress)) }
            }
        }
        return indexed.sorted { $0.0 < $1.0 }.map { (shows[$0.0], $0.1) }
    }
}
