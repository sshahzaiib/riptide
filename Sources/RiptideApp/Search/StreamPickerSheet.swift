import SwiftUI
import StreamCore

/// Merged stream results across all configured addons for one movie/episode.
struct StreamPickerSheet: View {
    let request: StreamRequest

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(LibraryModel.self) private var library
    @State private var model = StreamPickerModel()

    private enum UncachedSend { case inFlight, downloading, sent, failed }
    @State private var uncachedSend: UncachedSend?
    @State private var uncachedTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 560, height: 480)
        .task { await model.load(request) }
        .onDisappear { uncachedTask?.cancel() }
    }

    private var sheetTitle: String {
        if let season = request.season, let episode = request.episode {
            return "\(request.title) — S\(season)E\(episode)"
        }
        return request.title
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(sheetTitle).font(.headline)
                Spacer()
                if model.loadingCount > 0 {
                    ProgressView().controlSize(.small)
                }
                Button("Close") { dismiss() }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filterChip("All", id: nil)
                    ForEach(AppSettings.shared.addons) { addon in
                        filterChip(addon.name, id: addon.id)
                    }
                }
            }
        }
        .padding()
    }

    private func filterChip(_ label: String, id: UUID?) -> some View {
        Button(label) { model.filterAddonID = id }
            .buttonStyle(.bordered)
            .tint(model.filterAddonID == id ? .accentColor : .secondary)
    }

    @ViewBuilder
    private var content: some View {
        if AppSettings.shared.addons.isEmpty {
            ContentUnavailableView {
                Label("No addons configured", systemImage: "puzzlepiece.extension")
            } description: {
                Text("Add a debrid-configured addon in Settings › Addons to find streams.")
            }
        } else if let uncachedSend {
            switch uncachedSend {
            case .inFlight:
                ProgressView("Sending to your debrid service…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .downloading:
                VStack(spacing: 12) {
                    ProgressView(value: model.downloadProgress ?? 0, total: 100)
                        .frame(maxWidth: 280)
                    Text("Downloading on Real-Debrid… \(Int(model.downloadProgress ?? 0))%")
                        .foregroundStyle(.secondary)
                    Text("Playback starts automatically when it's ready.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .sent:
                ContentUnavailableView {
                    Label("Sent to your debrid service", systemImage: "tray.and.arrow.down")
                } description: {
                    Text("It will appear in your library once downloaded.")
                }
            case .failed:
                ContentUnavailableView {
                    Label("Couldn't send to your debrid service", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("Real-Debrid couldn't start this torrent — it may be dead. Try another stream.")
                } actions: {
                    Button("Back to Streams") { self.uncachedSend = nil }
                }
            }
        } else if model.visibleRows.isEmpty && model.loadingCount == 0 {
            ContentUnavailableView {
                Label("No streams found", systemImage: "magnifyingglass")
            } description: {
                Text(failureNote ?? "None of your addons returned streams for this title.")
            } actions: {
                Button("Retry") { Task { await model.load(request) } }
            }
        } else {
            List(model.visibleRows) { row in
                Button { select(row) } label: { rowView(row) }
                    .buttonStyle(.plain)
            }
            .listStyle(.inset)
            .safeAreaInset(edge: .bottom) {
                if let failureNote {
                    Text(failureNote)
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(6)
                        .background(.bar)
                }
            }
        }
    }

    private var failureNote: String? {
        guard !model.failedAddons.isEmpty else { return nil }
        return "\(model.failedAddons.joined(separator: ", ")) didn't respond."
    }

    private func rowView(_ row: StreamPickerModel.Row) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: row.meta.cached == false ? "arrow.down.circle" : "bolt.fill")
                .foregroundStyle(row.meta.cached == false ? Color.secondary : .yellow)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    if let resolution = row.meta.resolution {
                        Text(resolution).font(.subheadline.bold())
                    }
                    if let bytes = row.meta.sizeBytes {
                        Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    if row.meta.cached == false {
                        Text("NOT CACHED").font(.caption2.bold())
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    Spacer()
                    Text(row.addon.name).font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                    Button { copyLink(row) } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help(row.stream.infoHash != nil ? "Copy magnet link" : "Copy stream URL")
                }
                Text(row.stream.displayText)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    /// Prefer a real magnet link when the addon exposed the infohash;
    /// otherwise the debrid-resolved stream URL is the best we have.
    private func copyLink(_ row: StreamPickerModel.Row) {
        let text = row.stream.infoHash.map { "magnet:?xt=urn:btih:\($0)" }
            ?? row.stream.httpURL?.absoluteString
        guard let text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func select(_ row: StreamPickerModel.Row) {
        guard let url = row.stream.httpURL else { return }
        if row.meta.cached == false {
            uncachedSend = .inFlight
            uncachedTask = Task {
                switch await model.registerUncached(stream: row.stream) {
                case .added(let torrentID):
                    // Trackable on RD — wait out the download, then the
                    // resolver URL streams like any cached pick.
                    uncachedSend = .downloading
                    if await model.waitUntilDownloaded(torrentID: torrentID) {
                        startPlayback(url: url)
                    } else if !Task.isCancelled {
                        uncachedSend = .failed
                    }
                case .probed:
                    uncachedSend = .sent      // registered blind; nothing to poll
                case .failed:
                    uncachedSend = .failed
                }
            }
            return
        }
        startPlayback(url: url)
    }

    private func startPlayback(url: URL) {
        let key = "addon#\(request.imdbID):\(request.season ?? 0):\(request.episode ?? 0)"
        openWindow(value: PlayItem(itemKey: key,
                                   title: sheetTitle,
                                   url: url,
                                   resumeFrom: nil,
                                   subtitleQuery: request.title,
                                   season: request.season,
                                   episode: request.episode,
                                   tmdbID: request.tmdbID,
                                   autoResume: false))
        dismiss()
        // The addon's resolver only adds the torrent to the debrid account
        // once mpv actually requests the URL — give playback time to start
        // before refreshing, or the new item may not exist on RD yet.
        // ponytail: fixed delay; wire to a playback-start event if flaky.
        Task {
            try? await Task.sleep(for: .seconds(10))
            await library.refresh()
        }
    }
}
