import Foundation
import StreamCore

/// Unrestricts a library file's debrid link and assembles its PlayItem.
/// Shared by the detail-page play actions (via LibraryModel) and the
/// player window's Up Next flow.
enum PlayItemBuilder {
    @MainActor
    static func make(for item: LibraryItem, store: LibraryStore,
                     autoResume: Bool = false) async throws -> PlayItem {
        guard !item.link.isEmpty else { throw RealDebridError.noDownloadableLinks }
        let settings = AppSettings.shared
        let url: URL
        if item.service == "ad" {
            // Fail fast on a cleared key instead of a doomed network call.
            guard !settings.adToken.isEmpty else { throw AllDebridError.authFailed }
            url = try await AllDebridClient(token: settings.adToken).unlock(link: item.link)
        } else {
            let unrestricted = try await RealDebridClient(token: settings.rdToken)
                .unrestrictLink(item.link)
            guard let direct = unrestricted.directURL else { throw RealDebridError.badResponse }
            url = direct
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
