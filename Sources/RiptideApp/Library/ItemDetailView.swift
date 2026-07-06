import SwiftUI
import StreamCore
import class StreamCore.LibraryItem

struct ItemDetailView: View {
    @Environment(LibraryModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let item: LibraryItem
    @State private var busyIndex: Int?
    @State private var playError: String?

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 20) {
                AsyncImage(url: item.posterPath.map { TMDB.imageURL(path: $0) }) { image in
                    image.resizable().aspectRatio(contentMode: .fit)
                } placeholder: {
                    Rectangle().fill(.quaternary)
                }
                .frame(width: 220, height: 330)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 10) {
                    Text(item.title).font(.largeTitle.bold())
                    HStack(spacing: 12) {
                        if let year = item.year { Text(String(year)) }
                        if let quality = item.quality { Text(quality.uppercased()) }
                        if let rating = item.rating {
                            Label(String(format: "%.1f", rating), systemImage: "star.fill")
                        }
                    }
                    .foregroundStyle(.secondary)

                    if let overview = item.overview, !overview.isEmpty {
                        Text(overview).frame(maxWidth: 520, alignment: .leading)
                    }

                    Divider().frame(maxWidth: 520)

                    // A torrent can hold several files; RD gives us opaque links,
                    // so label by index. ponytail: per-file names need a
                    // torrentInfo call — add when multi-file packs feel blind.
                    ForEach(Array(item.links.enumerated()), id: \.offset) { index, _ in
                        Button(action: { Task { await play(index) } }) {
                            HStack {
                                if busyIndex == index { ProgressView().controlSize(.small) }
                                else { Image(systemName: "play.fill") }
                                Text(item.links.count == 1 ? "Play" : "Play file \(index + 1)")
                            }
                        }
                        .disabled(busyIndex != nil)
                    }
                    if let playError {
                        Text(playError).foregroundStyle(.red).font(.callout)
                    }
                }
                Spacer()
            }
            .padding(24)
        }
        .navigationTitle(item.title)
    }

    private func play(_ index: Int) async {
        busyIndex = index
        defer { busyIndex = nil }
        do {
            let playItem = try await model.playItem(for: item, fileIndex: index)
            openWindow(value: playItem)
        } catch {
            playError = "Could not start stream: \(error)"
        }
    }
}

struct ShowDetailView: View {
    let show: ShowGroup

    private var seasons: [(number: Int, episodes: [LibraryItem])] {
        Dictionary(grouping: show.episodes) { $0.season ?? 0 }
            .map { (number: $0.key, episodes: $0.value) }
            .sorted { $0.number < $1.number }
    }

    var body: some View {
        List {
            ForEach(seasons, id: \.number) { season in
                Section("Season \(season.number)") {
                    ForEach(season.episodes, id: \.torrentID) { episode in
                        NavigationLink(destination: ItemDetailView(item: episode)) {
                            HStack {
                                Text("E\(episode.episode ?? 0)")
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text(episode.filename).lineLimit(1)
                                Spacer()
                                if let quality = episode.quality {
                                    Text(quality).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(show.title)
    }
}
