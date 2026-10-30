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
                Section("Set up from another device") {
                    NavigationLink("Set up from another device") { PairingDestination() }
                }
                Section("About") {
                    Text("Riptide for Apple TV \(Self.info("CFBundleShortVersionString")) (\(Self.info("CFBundleVersion")))")
                    Text("github.com/sshahzaiib/riptide").foregroundStyle(.secondary)
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
private struct PairingDestination: View {
    @State private var server = PairingServer.live()
    @Environment(\.dismiss) private var dismiss

    var body: some View { PairingScreen(server: server, onContinue: { dismiss() }) }
}
