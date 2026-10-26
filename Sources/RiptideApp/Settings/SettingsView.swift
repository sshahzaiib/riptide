import SwiftUI
import AppKit
import StreamCore

struct SettingsView: View {
    /// Adopt externally-downloaded files in the media folder; returns the
    /// number newly adopted. Injected so Settings needn't reach the manager
    /// through the sheet's environment.
    var onScanFolder: (() -> Int)? = nil
    @State private var scanResult: String?
    @Environment(\.dismiss) private var dismiss
    @State private var rdToken = AppSettings.shared.rdToken
    @State private var adToken = AppSettings.shared.adToken
    @State private var tmdbToken = AppSettings.shared.tmdbToken
    @State private var openSubsKey = AppSettings.shared.openSubsKey
    @State private var traktClientID = TraktService.shared.clientID
    @State private var traktClientSecret = TraktService.shared.clientSecret
    @State private var showTraktConnect = false
    @AppStorage("autoplayNext") private var autoplayNext = true
    @AppStorage(StreamingCachePreset.storageKey)
    private var streamingCache: StreamingCachePreset = .default

    private var trakt: TraktService { TraktService.shared }

    @State private var cacheSize: String = "Calculating…"

    private func refreshCacheSize() async {
        let metadata = await MetadataCache.shared.diskBytesUsed()
        let total = Int64(URLCache.shared.currentDiskUsage) + metadata
        cacheSize = ByteCountFormatter.string(fromByteCount: total,
                                              countStyle: .file)
    }

    private func clearCache() async {
        URLCache.shared.removeAllCachedResponses()
        await MetadataCache.shared.clear()
        ShelfDiskCache.removeAll()
        // Wait for URLCache disk cleanup to settle so we don't display a stale size.
        try? await Task.sleep(nanoseconds: 500_000_000)
        await refreshCacheSize()
    }

    var body: some View {
        Form {
            Section("Playback") {
                Toggle("Autoplay next episode", isOn: $autoplayNext)
                Text("When an episode ends, the next one starts after a 10-second countdown.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Streaming cache", selection: $streamingCache) {
                    ForEach(StreamingCachePreset.allCases, id: \.self) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                Text("Aggressive buffers several minutes ahead — helps high-bitrate 4K remuxes. Applies to newly opened players.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Downloads") {
                @Bindable var settings = AppSettings.shared
                HStack {
                    VStack(alignment: .leading) {
                        Text("Riptide media folder").font(.callout)
                        Text(settings.mediaFolderPath.isEmpty
                             ? "Not set — pick where downloads are saved"
                             : settings.mediaFolderPath)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button("Choose…") { chooseMediaFolder() }
                    if !settings.mediaFolderPath.isEmpty {
                        Button("Reveal") {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [URL(fileURLWithPath: settings.mediaFolderPath)])
                        }
                    }
                }
                if !settings.mediaFolderPath.isEmpty, let onScanFolder {
                    HStack {
                        Button("Scan Folder Now") {
                            let n = onScanFolder()
                            scanResult = n == 0
                                ? "No new files found."
                                : "Adopted \(n) existing file\(n == 1 ? "" : "s")."
                        }
                        if let scanResult {
                            Text(scanResult).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    Text("Finds files already in the folder (e.g. downloaded from a debrid website) and marks them available offline.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Cache") {
                LabeledContent("Storage used", value: cacheSize)
                Button("Clear cache") { Task { await clearCache() } }
            }
            Section("Subtitles") {
                SubtitleStyleControls()
                Text("Applies to newly opened players. Adjust live from the player's captions menu.")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
        .task { await refreshCacheSize() }
        // The grouped form's internal scroll view lays out at ~580pt minimum
        // for this content and overflows (clips both edges) below that —
        // measured via offscreen NSHostingView renders. Min 600 clears it;
        // flexible max makes the sheet user-resizable, capped height keeps
        // it scrolling instead of outgrowing the window.
        .frame(minWidth: 600, maxWidth: .infinity,
               minHeight: 480, idealHeight: 660, maxHeight: .infinity)
        .padding(.bottom, 12)
    }

    private func chooseMediaFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            AppSettings.shared.setMediaFolder(url)
        }
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
