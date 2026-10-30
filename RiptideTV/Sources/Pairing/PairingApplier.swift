import Foundation
import StreamCore

/// Validates a submitted payload, stores what passes, and reports all seven fields.
/// An empty payload changes nothing. Bad values are never stored.
@MainActor
struct PairingApplier {
    let settings: AppSettings
    let trakt: TraktService
    let validators: PairingValidating

    init(settings: AppSettings, trakt: TraktService, validators: PairingValidating) {
        self.settings = settings
        self.trakt = trakt
        self.validators = validators
    }

    func apply(_ p: PairingPayload) async -> [PairingFieldState] {
        var rd = settings.rdToken, tmdb = settings.tmdbToken, ad = settings.adToken
        var osk = settings.openSubsKey
        var tID = trakt.clientID, tSecret = trakt.clientSecret
        var results: [String: String] = [:]

        // Validate the three keys concurrently; the user is waiting on a phone.
        let newRD = p.rdToken?.trimmed, newAD = p.adToken?.trimmed, newTMDB = p.tmdbToken?.trimmed
        async let rdOK: Bool? = newRD == nil ? nil : validators.check(rd: newRD!)
        async let adOK: Bool? = newAD == nil ? nil : validators.check(ad: newAD!)
        async let tmdbOK: Bool? = newTMDB == nil ? nil : validators.check(tmdb: newTMDB!)
        let (rdRes, adRes, tmdbRes) = await (rdOK, adOK, tmdbOK)

        if let v = newRD, let ok = rdRes { if ok { rd = v } else { results["rdToken"] = "Rejected by Real-Debrid" } }
        if let v = newAD, let ok = adRes { if ok { ad = v } else { results["adToken"] = "Rejected by AllDebrid" } }
        if let v = newTMDB, let ok = tmdbRes { if ok { tmdb = v } else { results["tmdbToken"] = "Rejected by TMDB" } }
        if let v = p.openSubsKey { osk = v }
        if let v = p.traktClientID { tID = v }
        if let v = p.traktClientSecret { tSecret = v }

        if p.clear.contains("rdToken") { rd = "" }
        if p.clear.contains("adToken") { ad = "" }
        if p.clear.contains("tmdbToken") { tmdb = "" }
        if p.clear.contains("openSubsKey") { osk = "" }
        if p.clear.contains("traktClientID") { tID = "" }
        if p.clear.contains("traktClientSecret") { tSecret = "" }

        // Only touch storage when something actually changed.
        if (rd, tmdb, osk, ad) != (settings.rdToken, settings.tmdbToken, settings.openSubsKey, settings.adToken) {
            settings.save(rdToken: rd, tmdbToken: tmdb, openSubsKey: osk, adToken: ad)
        }
        if (tID, tSecret) != (trakt.clientID, trakt.clientSecret) {
            trakt.saveCredentials(clientID: tID, clientSecret: tSecret)
        }

        var list = settings.addons
        var failed: [String] = []
        for raw in p.addonURLs.map(\.trimmed) where !raw.isEmpty {
            guard let addon = await validators.check(addon: raw) else { failed.append("Rejected: \(raw)"); continue }
            if !list.contains(where: { $0.url == addon.url }) { list.append(addon) }
        }
        if p.clear.contains("addonURLs") { list = [] }
        if list != settings.addons { settings.saveAddons(list) }
        if !failed.isEmpty { results["addonURLs"] = failed.joined(separator: "\n") }

        func s(_ name: String, _ label: String, _ isSet: Bool) -> PairingFieldState {
            PairingFieldState(name: name, label: label, isSet: isSet, result: results[name])
        }
        return [
            s("rdToken", "Real-Debrid token", !settings.rdToken.isEmpty),
            s("tmdbToken", "TMDB token", !settings.tmdbToken.isEmpty),
            s("adToken", "AllDebrid token", !settings.adToken.isEmpty),
            s("traktClientID", "Trakt client ID", !trakt.clientID.isEmpty),
            s("traktClientSecret", "Trakt client secret", !trakt.clientSecret.isEmpty),
            s("openSubsKey", "OpenSubtitles key", !settings.openSubsKey.isEmpty),
            s("addonURLs", "Addon URLs", !settings.addons.isEmpty),
        ]
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension PairingServer {
    /// The only construction site: real Keychain stores and live validators.
    static func live() -> PairingServer {
        let applier = PairingApplier(settings: .shared, trakt: .shared, validators: LiveValidators())
        return PairingServer(apply: { await applier.apply($0) })
    }
}
