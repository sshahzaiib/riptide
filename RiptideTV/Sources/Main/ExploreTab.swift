import SwiftUI
import StreamCore

struct ExploreTab: View {
    private let model = DiscoverModel.shared
    @State private var loaded = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 40) {
                ForEach(model.orderedShelves) { id in
                    if let shelf = model.shelves[id], shelf.state == .loaded, !shelf.items.isEmpty {
                        PosterRow(title: id.rawValue, items: shelf.items) { media in
                            PosterCard(title: media.title,
                                       posterURL: media.posterPath.map { TMDB.imageURL(path: $0, width: 342) }, width: 220, ref: .media(media))
                        }
                    }
                }
            }
            .padding(.vertical, 40)
        }
        .task {
            guard !loaded else { return }
            loaded = true
            model.load()
        }
    }
}
