import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var rdToken = AppSettings.shared.rdToken
    @State private var tmdbToken = AppSettings.shared.tmdbToken
    @State private var openSubsKey = AppSettings.shared.openSubsKey
    @State private var traktClientID = TraktService.shared.clientID
    @State private var traktClientSecret = TraktService.shared.clientSecret
    @State private var showTraktConnect = false

    private var trakt: TraktService { TraktService.shared }

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
            Section("Trakt (optional)") {
                SecureField("Client ID", text: $traktClientID)
                SecureField("Client Secret", text: $traktClientSecret)
                Link("Create an app at trakt.tv/oauth/applications",
                     destination: URL(string: "https://trakt.tv/oauth/applications")!)
                    .font(.caption)
                HStack {
                    if trakt.isConnected {
                        Label(trakt.needsReauth ? "Reconnect needed" : "Connected",
                              systemImage: trakt.needsReauth
                                ? "exclamationmark.triangle" : "checkmark.circle.fill")
                            .foregroundStyle(trakt.needsReauth ? .orange : .green)
                        Spacer()
                        Button("Disconnect") { trakt.disconnect() }
                        if trakt.needsReauth { connectButton }
                    } else {
                        Spacer()
                        connectButton
                    }
                }
            }
            HStack {
                Spacer()
                Button("Save") {
                    AppSettings.shared.save(rdToken: rdToken, tmdbToken: tmdbToken,
                                            openSubsKey: openSubsKey)
                    TraktService.shared.saveCredentials(clientID: traktClientID,
                                                        clientSecret: traktClientSecret)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(rdToken.isEmpty || tmdbToken.isEmpty)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showTraktConnect) { TraktConnectSheet() }
        .frame(width: 480)
        .padding(.bottom, 12)
    }

    private var connectButton: some View {
        Button("Connect…") {
            TraktService.shared.saveCredentials(clientID: traktClientID,
                                                clientSecret: traktClientSecret)
            showTraktConnect = true
        }
        .disabled(traktClientID.isEmpty || traktClientSecret.isEmpty)
    }
}
