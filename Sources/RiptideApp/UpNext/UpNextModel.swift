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

    struct Entry: Identifiable, Codable {
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
    private(set) var isLoadingMore = false
    /// Built items (playback + fetched shows) not yet resolved into cards.
    private var pendingItems: [UpNextItem] = []
    /// Shortlisted shows whose progress hasn't been fetched yet.
    private var pendingShows: [TraktWatchedShow] = []
    /// Bumped by every full (re)load and reset so a stale loadMore() page
    /// can't append onto entries it wasn't computed against.
    private var generation = 0
    private let pageSize = 20

    var hasMore: Bool { !pendingItems.isEmpty || !pendingShows.isEmpty }

    private var inFlight: Task<Void, Never>?
    /// Identifies the current inFlight task so a finishing load() only clears
    /// its own reference — otherwise a reset() + new load() racing the old
    /// await could nil out the new task's inFlight, letting a third load run.
    private var inFlightID: UUID?

    func entry(for media: SearchMedia) -> Entry? {
        entries.first { $0.media.id == media.id }
    }

    /// Called by TraktService on disconnect so a reconnect doesn't show the
    /// previous account's rail.
    func reset() {
        inFlight?.cancel()
        inFlight = nil
        inFlightID = nil
        entries = []
        pendingItems = []
        pendingShows = []
        isLoadingMore = false
        generation += 1
        state = .idle
        ShelfDiskCache.remove(name: "upnext")
    }

    /// Single-flight; a loaded rail keeps rendering while it revalidates.
    func load() async {
        if let inFlight { await inFlight.value; return }
        let id = UUID()
        let task = Task { await self.doLoad() }
        inFlight = task
        inFlightID = id
        await task.value
        if inFlightID == id {
            inFlight = nil
            inFlightID = nil
        }
    }

    private func doLoad() async {
        guard let trakt = TraktService.shared.client else {
            entries = []; state = .idle
            return
        }
        if state == .idle,
           let cached = ShelfDiskCache.load([Entry].self, name: "upnext") {
            entries = cached
            state = .loaded
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
            // Full sorted shortlist, but progress is fetched one page at a
            // time — loadMore() pulls the next pageSize shows on demand, so
            // a large watch history never fans out all at once.
            let shortlist = UpNextBuilder.shortlist(watched: watched, hiddenTMDBIDs: hiddenIDs,
                                                    cap: .max)
            let progress = await fetchProgress(for: Array(shortlist.prefix(pageSize)),
                                               client: trakt)
            let items = UpNextBuilder.build(playback: playback, progressByShow: progress)
            // First page is pageSize entries total — playback can alone
            // exceed it; the overflow waits in pendingItems for loadMore().
            let firstPage = Array(items.prefix(pageSize))

            // resolveTMDBCards is 1:1 and order-preserving, so zip is safe.
            let cards = await resolveTMDBCards(firstPage.map { (isShow: $0.isShow, id: $0.tmdbID,
                                                                title: "", year: nil as Int?) })
            // A reset() (Trakt disconnect) may have landed while the above
            // awaits were suspended — don't let a stale account's results
            // overwrite the reset state.
            guard TraktService.shared.client === trakt else { return }
            // resolveTMDBCards swallows CancellationError and returns fallback
            // cards instead of throwing, so a cancelled load must be caught
            // here explicitly before it writes state.
            if Task.isCancelled { return }
            entries = zip(cards, firstPage).map { Entry(media: $0, item: $1) }
            pendingItems = Array(items.dropFirst(pageSize))
            pendingShows = Array(shortlist.dropFirst(pageSize))
            generation += 1
            state = .loaded
            ShelfDiskCache.save(Array(entries.prefix(pageSize)), name: "upnext")
        } catch {
            guard TraktService.shared.client === trakt else { return }
            if Task.isCancelled { return }
            if !wasLoaded { state = .failed }
        }
    }

    /// Fetch progress for the next page of pending shows and append their
    /// entries. Individual failures just drop those shows (fetchProgress
    /// never throws), so the page always consumes — a page can therefore
    /// yield fewer than pageSize new cards (completed shows have no next
    /// episode).
    func loadMore() async {
        guard state == .loaded, !isLoadingMore, hasMore,
              let trakt = TraktService.shared.client else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let gen = generation
        // Work on local copies; commit back only after the staleness guards.
        var queue = pendingItems
        var shows = pendingShows
        var known = Set((entries.map(\.item) + queue).map(dedupKey))
        // Top the queue up to a full page — completed shows have no next
        // episode, so one fetched page can yield fewer than pageSize items.
        while queue.count < pageSize && !shows.isEmpty {
            let page = Array(shows.prefix(pageSize))
            let progress = await fetchProgress(for: page, client: trakt)
            queue += UpNextBuilder.build(playback: [], progressByShow: progress)
                .filter { known.insert(dedupKey($0)).inserted }
            shows.removeFirst(page.count)
        }
        let batch = Array(queue.prefix(pageSize))
        let cards = await resolveTMDBCards(batch.map { (isShow: $0.isShow, id: $0.tmdbID,
                                                        title: "", year: nil as Int?) })
        // A reset or full reload landed while we were suspended — this page
        // was computed against stale entries/pending, so drop it.
        guard TraktService.shared.client === trakt, generation == gen else { return }
        entries += zip(cards, batch).map { Entry(media: $0, item: $1) }
        pendingItems = Array(queue.dropFirst(batch.count))
        pendingShows = shows
    }

    private func dedupKey(_ item: UpNextItem) -> String {
        "\(item.isShow ? "show" : "movie")-\(item.tmdbID)"
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
                    (index, try? await client.showProgress(traktID: traktID,
                                                           lastActivity: show.lastWatchedAt))
                }
            }
            for await (index, progress) in group {
                if let progress { indexed.append((index, progress)) }
            }
        }
        return indexed.sorted { $0.0 < $1.0 }.map { (shows[$0.0], $0.1) }
    }
}
