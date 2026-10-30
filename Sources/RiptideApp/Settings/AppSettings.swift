import Foundation
import Observation
import StreamCore

/// A configured Stremio addon. `url` is the debrid-configured base URL — it
/// embeds the user's debrid API key, so the list lives in Keychain only.
/// `service` routes uncached picks; nil (undetected/legacy) behaves as RD.
struct ConfiguredAddon: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var url: URL
    var service: DebridServiceID?
}

@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let keychain: KeychainStore
    private(set) var rdToken: String
    private(set) var mediaFolderPath: String
    private(set) var adToken: String
    private(set) var tmdbToken: String
    private(set) var openSubsKey: String
    private(set) var addons: [ConfiguredAddon]

    init(keychain: KeychainStore = KeychainStore()) {
        self.keychain = keychain
        rdToken = keychain.get("rd-token") ?? ""
        mediaFolderPath = keychain.get("media-folder") ?? ""
        adToken = keychain.get("ad-token") ?? ""
        tmdbToken = keychain.get("tmdb-token") ?? ""
        openSubsKey = keychain.get("opensubtitles-key") ?? ""
        addons = Self.decodeAddons(keychain.get("stremio-addons"))
    }

    /// RD + TMDB are required for the library; OpenSubtitles is optional.
    var isConfigured: Bool { !rdToken.isEmpty && !tmdbToken.isEmpty }

    func save(rdToken: String, tmdbToken: String, openSubsKey: String, adToken: String) {
        self.rdToken = rdToken.trimmingCharacters(in: .whitespacesAndNewlines)
        self.tmdbToken = tmdbToken.trimmingCharacters(in: .whitespacesAndNewlines)
        self.openSubsKey = openSubsKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.adToken = adToken.trimmingCharacters(in: .whitespacesAndNewlines)
        keychain.set(self.rdToken, account: "rd-token")
        keychain.set(self.tmdbToken, account: "tmdb-token")
        keychain.set(self.openSubsKey, account: "opensubtitles-key")
        keychain.set(self.adToken, account: "ad-token")
    }

    func saveAddons(_ list: [ConfiguredAddon]) {
        addons = list
        if let data = try? JSONEncoder().encode(list),
           let json = String(data: data, encoding: .utf8) {
            keychain.set(json, account: "stremio-addons")
        }
    }

    var mediaFolderURL: URL? {
        mediaFolderPath.isEmpty ? nil : URL(fileURLWithPath: mediaFolderPath)
    }

    func setMediaFolder(_ url: URL) {
        mediaFolderPath = url.path
        keychain.set(mediaFolderPath, account: "media-folder")
    }

    private static func decodeAddons(_ json: String?) -> [ConfiguredAddon] {
        guard let json, let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([ConfiguredAddon].self, from: data)
        else { return [] }
        return list
    }
}
