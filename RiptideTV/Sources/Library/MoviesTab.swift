import SwiftUI
import StreamCore

struct MoviesTab: View {
    let library: LibraryModel
    @State private var loaded = false

    var body: some View {
        PosterGrid(items: library.movies) { item in
            PosterCard(title: item.title.isEmpty ? item.filename : item.title,
                       posterURL: item.posterPath.map { TMDB.imageURL(path: $0, width: 342) }) {
                // Task 10: open TitlePage
            }
        }
        .task {
            guard !loaded else { return }
            loaded = true
            await library.refresh()
        }
    }
}
