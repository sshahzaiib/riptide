import Foundation
import StreamCore
import class StreamCore.LibraryItem

/// Turns "play this title" into a PlayItem without UI: a library file when we
/// own one, otherwise the top addon stream (same URL path as StreamPickerSheet).
@MainActor
enum PlayResolver {
    enum Error: LocalizedError {
        case nothingToPlay, noCachedStream
        var errorDescription: String? {
            switch self {
            case .nothingToPlay: "Nothing to play: no library file and no addon streams found."
            case .noCachedStream: "No cached streams available. Open Other versions to pick one."
            }
        }
    }

    static func best(libraryItems: [LibraryItem], request: StreamRequest?,
                     store: LibraryStore) async throws -> PlayItem {
        if !libraryItems.isEmpty {
            let states = Dictionary(((try? store.allWatchStates()) ?? []).map { ($0.itemKey, $0) },
                                    uniquingKeysWith: { a, _ in a })
            let item = VersionPreference.preferred(items: libraryItems, states: states)!
            return try await PlayItemBuilder.make(for: item, store: store)
        }
        guard let request else { throw Error.nothingToPlay }
        let model = StreamPickerModel()
        await model.load(request)
        guard !model.rows.isEmpty else { throw Error.nothingToPlay }
        // Rows are pre-sorted (cached first, resolution desc); skip known-uncached.
        guard let url = model.rows.first(where: { $0.meta.cached != false })?.stream.httpURL
        else { throw Error.noCachedStream }
        return playItem(url: url, request: request)
    }

    /// Mirrors StreamPickerSheet.startPlayback(url:).
    static func playItem(url: URL, request: StreamRequest) -> PlayItem {
        var title = request.title
        if let s = request.season, let e = request.episode { title += " — S\(s)E\(e)" }
        let key = "addon#\(request.imdbID):\(request.season ?? 0):\(request.episode ?? 0)"
        let resume = (try? AppModels.store.continueWatching())?.first { $0.itemKey == key }?.positionSeconds
        return PlayItem(itemKey: key,
                        title: title, url: url, resumeFrom: resume, subtitleQuery: request.title,
                        season: request.season, episode: request.episode,
                        tmdbID: request.tmdbID, autoResume: false)
    }

    /// The addon resolver only adds the torrent to the debrid account once
    /// playback requests the URL; refresh later so the new file appears.
    static func refreshLibraryLater(for item: PlayItem) {
        guard item.itemKey.hasPrefix("addon#") else { return }
        Task {
            try? await Task.sleep(for: .seconds(10))
            await AppModels.library.refresh()
        }
    }
}

enum PlayStart { case ask, resume, fromStart }

extension PlayItem {
    func starting(_ s: PlayStart) -> PlayItem {
        switch s {
        case .ask: return self
        case .resume:
            return PlayItem(itemKey: itemKey, title: title, url: url, resumeFrom: resumeFrom,
                            subtitleQuery: subtitleQuery, season: season, episode: episode,
                            tmdbID: tmdbID, autoResume: true)
        case .fromStart:
            return PlayItem(itemKey: itemKey, title: title, url: url, resumeFrom: nil,
                            subtitleQuery: subtitleQuery, season: season, episode: episode,
                            tmdbID: tmdbID, autoResume: autoResume)
        }
    }
}
