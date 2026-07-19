import Foundation
import StreamCore

/// Unrestricts a library file's debrid link and assembles its PlayItem.
/// Shared by the detail-page play actions (via LibraryModel) and the
/// player window's Up Next flow.
enum PlayItemBuilder {
    @MainActor
    static func make(for item: LibraryItem, store: LibraryStore,
                     autoResume: Bool = false) async throws -> PlayItem {
        let url: URL
        if let rec = try? store.downloadRecord(itemKey: item.itemKey),
           rec.state == .completed,
           FileManager.default.fileExists(atPath: rec.localPath) {
            url = URL(fileURLWithPath: rec.localPath)   // play from disk, offline
        } else {
            url = try await DebridResolver.directURL(for: item)
        }
        let resume = (try? store.continueWatching())?
            .first { $0.itemKey == item.itemKey }?.positionSeconds
        let title = item.season != nil
            ? "\(item.title) S\(item.season!)E\(item.episode ?? 0)"
            : item.title
        return PlayItem(itemKey: item.itemKey,
                        title: title,
                        url: url,
                        resumeFrom: resume,
                        subtitleQuery: item.title,
                        season: item.season,
                        episode: item.episode,
                        tmdbID: item.tmdbID,
                        autoResume: autoResume)
    }
}
