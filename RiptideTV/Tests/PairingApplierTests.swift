import XCTest
import StreamCore
@testable import RiptideTV

@MainActor
final class PairingApplierTests: XCTestCase {
    struct Fake: PairingValidating {
        var rdOK = true, adOK = true, tmdbOK = true
        var addon: ConfiguredAddon? = nil
        func check(rd: String) async -> Bool { rdOK }
        func check(ad: String) async -> Bool { adOK }
        func check(tmdb: String) async -> Bool { tmdbOK }
        func check(addon: String) async -> ConfiguredAddon? { self.addon }
    }

    private func makeSettings() -> AppSettings {
        AppSettings(keychain: KeychainStore(service: "test.\(UUID())"))
    }
    private func makeTrakt() -> TraktService {
        TraktService(keychain: KeychainStore(service: "test.\(UUID())"))
    }

    func testApplyKeepsExistingOnFailure() async {
        let settings = makeSettings()
        settings.save(rdToken: "good", tmdbToken: "t", openSubsKey: "", adToken: "")
        let applier = PairingApplier(settings: settings, trakt: makeTrakt(), validators: Fake(rdOK: false))
        var p = PairingPayload(); p.rdToken = "bad"
        let states = await applier.apply(p)
        XCTAssertEqual(settings.rdToken, "good")
        XCTAssertEqual(states.first { $0.name == "rdToken" }?.result, "Rejected by Real-Debrid")
        XCTAssertTrue(states.first { $0.name == "rdToken" }!.isSet)
    }

    func testClearErasesField() async {
        let settings = makeSettings()
        settings.save(rdToken: "r", tmdbToken: "t", openSubsKey: "", adToken: "a")
        let applier = PairingApplier(settings: settings, trakt: makeTrakt(), validators: Fake())
        var p = PairingPayload(); p.clear = ["adToken"]
        _ = await applier.apply(p)
        XCTAssertEqual(settings.adToken, "")
    }

    func testAddonAppendedOnceByURL() async {
        let settings = makeSettings()
        let addon = ConfiguredAddon(id: UUID(), name: "A", url: URL(string: "https://a/")!, service: nil)
        let applier = PairingApplier(settings: settings, trakt: makeTrakt(), validators: Fake(addon: addon))
        var p = PairingPayload()
        p.addonURLs = ["https://a/manifest.json", "https://a/manifest.json"]
        _ = await applier.apply(p)
        _ = await applier.apply(p)
        XCTAssertEqual(settings.addons.count, 1)
    }

    func testEmptyPayloadReportsStateWithoutChanges() async {
        let settings = makeSettings()
        settings.save(rdToken: "r", tmdbToken: "t", openSubsKey: "", adToken: "")
        let applier = PairingApplier(settings: settings, trakt: makeTrakt(), validators: Fake(rdOK: false))
        let states = await applier.apply(PairingPayload())
        XCTAssertEqual(settings.rdToken, "r")
        XCTAssertEqual(settings.tmdbToken, "t")
        XCTAssertEqual(states.map(\.name), ["rdToken", "tmdbToken", "adToken", "traktClientID", "traktClientSecret", "openSubsKey", "addonURLs"])
        let rd = states.first { $0.name == "rdToken" }!
        XCTAssertTrue(rd.isSet)
        XCTAssertNil(rd.result)
    }
}
