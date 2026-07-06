import Foundation
import Observation

@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let keychain = KeychainStore()
    private(set) var rdToken: String
    private(set) var tmdbToken: String
    private(set) var openSubsKey: String

    init() {
        rdToken = keychain.get("rd-token") ?? ""
        tmdbToken = keychain.get("tmdb-token") ?? ""
        openSubsKey = keychain.get("opensubtitles-key") ?? ""
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
}
