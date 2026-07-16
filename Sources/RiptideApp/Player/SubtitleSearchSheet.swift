import SwiftUI
import StreamCore

struct SubtitleSearchSheet: View {
    let itemKey: String            // "" for debug-URL playback → no caching
    let season: Int?
    let episode: Int?
    let onPicked: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query: String
    @State private var results: [SubtitleResult] = []
    @State private var status: String?
    @State private var searching = false
    @State private var downloading = false
    @State private var cachedIDs: Set<Int> = []

    init(query: String, itemKey: String, season: Int?, episode: Int?,
         onPicked: @escaping (String) -> Void) {
        _query = State(initialValue: query)
        self.itemKey = itemKey
        self.season = season
        self.episode = episode
        self.onPicked = onPicked
    }

    private var client: OpenSubtitlesClient? {
        let key = AppSettings.shared.openSubsKey
        return key.isEmpty ? nil : OpenSubtitlesClient(apiKey: key)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("Search subtitles", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await search() } }
                Button("Search") { Task { await search() } }
                    .disabled(searching || query.isEmpty)
            }
            if let status {
                Text(status).foregroundStyle(.secondary)
            }
            List(results, id: \.id) { result in
                Button(action: { Task { await download(result) } }) {
                    VStack(alignment: .leading) {
                        Text(result.release).lineLimit(1)
                        HStack(spacing: 6) {
                            Text(result.language).font(.caption).foregroundStyle(.secondary)
                            if cachedIDs.contains(result.fileID) {
                                Text("Downloaded").font(.caption).foregroundStyle(.tint)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(downloading)
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }
            }
        }
        .padding()
        .frame(width: 420, height: 380)
        .task {
            cachedIDs = SubtitleCache.cachedFileIDs(for: itemKey)
            await search()
        }
    }

    private func search() async {
        guard let client else {
            status = "Add an OpenSubtitles API key in Settings first."
            return
        }
        searching = true
        defer { searching = false }
        do {
            results = try await client.search(query: query, season: season, episode: episode)
            status = results.isEmpty ? "No results." : nil
        } catch {
            status = "Search failed: \(error)"
        }
    }

    private func download(_ result: SubtitleResult) async {
        // Cache hit: load from disk, no API call (OpenSubtitles quotas are per-download).
        if let cached = SubtitleCache.cachedFile(for: itemKey, fileID: result.fileID) {
            onPicked(cached.path)
            dismiss()
            return
        }
        guard let client, !downloading else { return }
        downloading = true
        defer { downloading = false }
        do {
            let itemDir = SubtitleCache.directory(for: itemKey, create: true)
            let dir: URL
            if let itemDir {
                dir = itemDir
            } else {
                // Debug-URL playback (or folder-creation failure): old
                // session-only Caches behavior, unchanged.
                dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Riptide/subs", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            var file = try await client.downloadSubtitle(fileID: result.fileID, into: dir)
            if itemDir != nil {
                file = try SubtitleCache.prefixed(file, fileID: result.fileID)
            }
            onPicked(file.path)
            dismiss()
        } catch {
            status = "Download failed: \(error)"
        }
    }
}
