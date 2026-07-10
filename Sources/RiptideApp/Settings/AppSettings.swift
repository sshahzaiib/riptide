import Foundation
import Observation

/// A configured Stremio addon. `url` is the debrid-configured base URL — it
/// embeds the user's debrid API key, so the list lives in Keychain only.
struct ConfiguredAddon: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var url: URL
}

@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let keychain = KeychainStore()
    private(set) var rdToken: String
    private(set) var tmdbToken: String
    private(set) var openSubsKey: String
    private(set) var addons: [ConfiguredAddon]

    init() {
        rdToken = keychain.get("rd-token") ?? ""
        tmdbToken = keychain.get("tmdb-token") ?? ""
        openSubsKey = keychain.get("opensubtitles-key") ?? ""
        addons = Self.decodeAddons(keychain.get("stremio-addons"))
    }

    /// RD + TMDB are required for the library; OpenSubtitles is optional.
    var isConfigured: Bool { !rdToken.isEmpty && !tmdbToken.isEmpty }

    func save(rdToken: String, tmdbToken: String, openSubsKey: String) {
        self.rdToken = rdToken.trimmingCharacters(in: .whitespacesAndNewlines)
        self.tmdbToken = tmdbToken.trimmingCharacters(in: .whitespacesAndNewlines)
        self.openSubsKey = openSubsKey.trimmingCharacters(in: .whitespacesAndNewlines)
        keychain.set(self.rdToken, account: "rd-token")
        keychain.set(self.tmdbToken, account: "tmdb-token")
        keychain.set(self.openSubsKey, account: "opensubtitles-key")
    }

    func saveAddons(_ list: [ConfiguredAddon]) {
        addons = list
        if let data = try? JSONEncoder().encode(list),
           let json = String(data: data, encoding: .utf8) {
            keychain.set(json, account: "stremio-addons")
        }
    }

    private static func decodeAddons(_ json: String?) -> [ConfiguredAddon] {
        guard let json, let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([ConfiguredAddon].self, from: data)
        else { return [] }
        return list
    }
}
