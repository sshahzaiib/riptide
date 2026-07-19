import Foundation
import StreamCore

/// Resolves a library item's debrid hoster link to a direct, playable/
/// downloadable URL. Shared by playback, download, and copy-link.
/// `@MainActor`: `item` is a SwiftData `@Model` and must be read on its
/// owning actor.
enum DebridResolver {
    @MainActor
    static func directURL(for item: LibraryItem) async throws -> URL {
        guard !item.link.isEmpty else { throw RealDebridError.noDownloadableLinks }
        let settings = AppSettings.shared
        if item.service == "ad" {
            guard !settings.adToken.isEmpty else { throw AllDebridError.authFailed }
            return try await AllDebridClient(token: settings.adToken).unlock(link: item.link)
        }
        let unrestricted = try await RealDebridClient(token: settings.rdToken)
            .unrestrictLink(item.link)
        guard let direct = unrestricted.directURL else { throw RealDebridError.badResponse }
        return direct
    }
}
