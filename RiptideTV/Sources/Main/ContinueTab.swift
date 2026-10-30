import SwiftUI
import StreamCore

struct ContinueTab: View {
    let library: LibraryModel
    private let upNext = UpNextModel.shared
    @State private var loaded = false

    private var showUpNext: Bool { TraktService.shared.isConnected && !upNext.entries.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                if showUpNext {
                    PosterRow(title: "Up next", items: upNext.entries) { entry in
                        PosterCard(title: entry.media.title,
                                   posterURL: entry.media.posterPath.map { TMDB.imageURL(path: $0, width: 780) },
                                   progress: entry.item.progressPercent.map { $0 / 100 },
                                   wide: true) {
                            // Task 10: open TitlePage
                        }
                        .frame(width: 520)
                    }
                }
                if !library.continueWatching.isEmpty {
                    PosterRow(title: "Continue watching", items: library.continueWatching) { entry in
                        PosterCard(title: entry.item.title.isEmpty ? entry.item.filename : entry.item.title,
                                   posterURL: entry.item.posterPath.map { TMDB.imageURL(path: $0, width: 780) },
                                   progress: entry.state.durationSeconds > 0
                                       ? entry.state.positionSeconds / entry.state.durationSeconds : 0,
                                   wide: true) {
                            // Task 10: open TitlePage
                        }
                        .frame(width: 520)
                    }
                }
                if !showUpNext && library.continueWatching.isEmpty {
                    Text("Nothing to continue yet").font(.title3).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.top, 200)
                }
            }
            .padding(.vertical, 40)
        }
        .task {
            guard !loaded else { return }
            loaded = true
            if TraktService.shared.isConnected { await upNext.load() }
        }
    }
}
