import SwiftUI
import StreamCore

struct WatchlistTab: View {
    private let model = WatchlistModel.shared
    @State private var loaded = false

    var body: some View {
        Group {
            if TraktService.shared.isConnected {
                PosterGrid(items: model.items) { media in
                    PosterCard(title: media.title,
                               posterURL: media.posterPath.map { TMDB.imageURL(path: $0, width: 342) }, ref: .media(media))
                }
            } else {
                Text("Sign in to Trakt in Settings to see your watchlist")
                    .font(.title3).foregroundStyle(.secondary)
            }
        }
        .task {
            guard !loaded else { return }
            loaded = true
            if TraktService.shared.isConnected { await model.load() }
        }
    }
}
