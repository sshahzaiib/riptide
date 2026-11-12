import SwiftUI

struct SettingsTab: View {
    private let settings = AppSettings.shared

    var body: some View {
        NavigationStack {
            List {
                ServicesSection(settings: settings)
                TraktSection()
                AddonsList(settings: settings)
                PlaybackSection()
                // Version lives in this footer, not its own section: plain-text
                // rows below the last focusable row can't be scrolled into view.
                Section {
                    NavigationLink("Set up from another device") { PairingDestination() }
                } header: {
                    Text("Set up from another device")
                } footer: {
                    Text("Riptide for Apple TV \(Self.info("CFBundleShortVersionString")) (\(Self.info("CFBundleVersion"))) · github.com/sshahzaiib/riptide")
                }
            }
            .navigationTitle("Settings")
        }
    }

    private static func info(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "?"
    }
}

/// Wrapper so each visit builds a fresh listener + token.
struct PairingDestination: View {
    @State private var server = PairingServer.live()
    @Environment(\.dismiss) private var dismiss

    var body: some View { PairingScreen(server: server, onContinue: { dismiss() }) }
}
