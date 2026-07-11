import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var rdToken = AppSettings.shared.rdToken
    @State private var adToken = AppSettings.shared.adToken
    @State private var tmdbToken = AppSettings.shared.tmdbToken
    @State private var openSubsKey = AppSettings.shared.openSubsKey
    @State private var traktClientID = TraktService.shared.clientID
    @State private var traktClientSecret = TraktService.shared.clientSecret
    @State private var showTraktConnect = false

    private var trakt: TraktService { TraktService.shared }

    var body: some View {
        Form {
            Section("Real-Debrid") {
                SecureField("API token", text: $rdToken).frame(maxWidth: .infinity)
                Link("Get your token at real-debrid.com/apitoken",
                     destination: URL(string: "https://real-debrid.com/apitoken")!)
                    .font(.caption)
            }
            Section("AllDebrid (optional backup)") {
                SecureField("API key", text: $adToken).frame(maxWidth: .infinity)
                Link("Get your key at alldebrid.com/apikeys",
                     destination: URL(string: "https://alldebrid.com/apikeys")!)
                    .font(.caption)
            }
            Section("TMDB (posters & metadata)") {
                SecureField("API Read Access Token (v4)", text: $tmdbToken).frame(maxWidth: .infinity)
                Link("Create a free key at themoviedb.org/settings/api",
                     destination: URL(string: "https://www.themoviedb.org/settings/api")!)
                    .font(.caption)
            }
            Section("OpenSubtitles (optional)") {
                SecureField("API key", text: $openSubsKey).frame(maxWidth: .infinity)
                Link("Create a free key at opensubtitles.com/consumers",
                     destination: URL(string: "https://www.opensubtitles.com/en/consumers")!)
                    .font(.caption)
            }
            Section("Trakt (optional)") {
                SecureField("Client ID", text: $traktClientID).frame(maxWidth: .infinity)
                SecureField("Client Secret", text: $traktClientSecret).frame(maxWidth: .infinity)
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
            AddonsSection()
            HStack {
                Spacer()
                Button("Save") {
                    AppSettings.shared.save(rdToken: rdToken, tmdbToken: tmdbToken,
                                            openSubsKey: openSubsKey, adToken: adToken)
                    LibraryModel.resetADAuth()
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
        // The grouped form's internal scroll view lays out at ~580pt minimum
        // for this content and overflows (clips both edges) below that —
        // measured via offscreen NSHostingView renders. Min 600 clears it;
        // flexible max makes the sheet user-resizable, capped height keeps
        // it scrolling instead of outgrowing the window.
        .frame(minWidth: 600, maxWidth: .infinity,
               minHeight: 480, idealHeight: 660, maxHeight: .infinity)
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
