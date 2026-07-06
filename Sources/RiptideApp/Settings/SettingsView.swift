import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var rdToken = AppSettings.shared.rdToken
    @State private var tmdbToken = AppSettings.shared.tmdbToken
    @State private var openSubsKey = AppSettings.shared.openSubsKey

    var body: some View {
        Form {
            Section("Real-Debrid") {
                SecureField("API token", text: $rdToken)
                Link("Get your token at real-debrid.com/apitoken",
                     destination: URL(string: "https://real-debrid.com/apitoken")!)
                    .font(.caption)
            }
            Section("TMDB (posters & metadata)") {
                SecureField("API Read Access Token (v4)", text: $tmdbToken)
                Link("Create a free key at themoviedb.org/settings/api",
                     destination: URL(string: "https://www.themoviedb.org/settings/api")!)
                    .font(.caption)
            }
            Section("OpenSubtitles (optional)") {
                SecureField("API key", text: $openSubsKey)
                Link("Create a free key at opensubtitles.com/consumers",
                     destination: URL(string: "https://www.opensubtitles.com/en/consumers")!)
                    .font(.caption)
            }
            HStack {
                Spacer()
                Button("Save") {
                    AppSettings.shared.save(rdToken: rdToken, tmdbToken: tmdbToken,
                                            openSubsKey: openSubsKey)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(rdToken.isEmpty || tmdbToken.isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding(.bottom, 12)
    }
}
