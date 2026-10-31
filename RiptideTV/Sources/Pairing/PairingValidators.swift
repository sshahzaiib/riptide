import Foundation
import StreamCore

/// Cheap authenticated calls used to vet a key before it is stored.
/// Any failure (bad key or network) counts as a rejection; the user can resubmit.
protocol PairingValidating {
    func check(rd: String) async -> Bool
    func check(ad: String) async -> Bool
    func check(tmdb: String) async -> Bool
    func check(addon: String) async -> ConfiguredAddon?
}

struct LiveValidators: PairingValidating {
    func check(rd: String) async -> Bool {
        (try? await RealDebridClient(token: rd).accountInfo()) != nil
    }
    func check(ad: String) async -> Bool {
        (try? await AllDebridClient(token: ad).magnetStatusList()) != nil
    }
    func check(tmdb: String) async -> Bool {
        (try? await TMDBClient(bearerToken: tmdb).trendingMovies()) != nil
    }
    func check(addon: String) async -> ConfiguredAddon? {
        // Same 5 s .addon session the Mac uses so a dead URL fails fast.
        let validator = AddonValidator(client: StremioAddonClient(session: .addon))
        guard let r = try? await validator.validate(rawURL: addon) else { return nil }
        return ConfiguredAddon(id: UUID(), name: r.manifest.name, url: r.baseURL,
                               service: DebridServiceID.detect(fromAddonURL: r.baseURL))
    }
}
