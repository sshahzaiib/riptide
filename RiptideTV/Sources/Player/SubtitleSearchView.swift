import SwiftUI
import StreamCore

/// tvOS port of the Mac SubtitleSearchSheet download path.
struct SubtitleSearchView: View {
    let model: PlayerModel
    let item: PlayItem
    let onDone: () -> Void
    @State private var query: String
    @State private var results: [SubtitleResult] = []
    @State private var status: String?
    @State private var busy = false

    init(model: PlayerModel, item: PlayItem, onDone: @escaping () -> Void) {
        self.model = model; self.item = item; self.onDone = onDone
        _query = State(initialValue: item.subtitleQuery)
    }

    private var client: OpenSubtitlesClient? {
        let key = AppSettings.shared.openSubsKey
        return key.isEmpty ? nil : OpenSubtitlesClient(apiKey: key)
    }

    var body: some View {
        List {
            TextField("Search subtitles", text: $query).onSubmit { Task { await search() } }
            if let status { Text(status).foregroundStyle(.secondary) }
            ForEach(results, id: \.id) { r in
                Button { Task { await download(r) } } label: {
                    VStack(alignment: .leading) {
                        Text(r.release).lineLimit(1)
                        Text(r.language).font(.caption).foregroundStyle(.secondary)
                    }
                }.disabled(busy)
            }
        }
        .task { await search() }
    }

    private func search() async {
        guard let client else { status = "Add an OpenSubtitles API key first."; return }
        do {
            results = try await client.search(query: query, season: item.season, episode: item.episode)
            status = results.isEmpty ? "No results." : nil
        } catch { status = "Search failed: \(error)" }
    }

    private func download(_ r: SubtitleResult) async {
        let key = item.itemKey
        if let cached = SubtitleCache.cachedFile(for: key, fileID: r.fileID) {
            model.addSubtitle(path: cached.path, expecting: key); onDone(); return
        }
        guard let client else { return }
        busy = true; defer { busy = false }
        do {
            let itemDir = SubtitleCache.directory(for: key, create: true)
            let dir = itemDir ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Riptide/subs", isDirectory: true)
            if itemDir == nil { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
            var file = try await client.downloadSubtitle(fileID: r.fileID, into: dir)
            if itemDir != nil {
                do { file = try SubtitleCache.prefixed(file, fileID: r.fileID) }
                catch { try? FileManager.default.removeItem(at: file); throw error }
            }
            model.addSubtitle(path: file.path, expecting: key)
            onDone()
        } catch { status = "Download failed: \(error)" }
    }
}
