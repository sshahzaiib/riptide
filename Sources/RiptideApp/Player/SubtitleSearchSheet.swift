import SwiftUI
import StreamCore

struct SubtitleSearchSheet: View {
    let season: Int?
    let episode: Int?
    let onPicked: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query: String
    @State private var results: [SubtitleResult] = []
    @State private var status: String?
    @State private var searching = false

    init(query: String, season: Int?, episode: Int?, onPicked: @escaping (String) -> Void) {
        _query = State(initialValue: query)
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
                        Text(result.language).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }
            }
        }
        .padding()
        .frame(width: 420, height: 380)
        .task { await search() }
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
        guard let client else { return }
        do {
            let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Riptide/subs", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = try await client.downloadSubtitle(fileID: result.fileID, into: dir)
            onPicked(file.path)
            dismiss()
        } catch {
            status = "Download failed: \(error)"
        }
    }
}
