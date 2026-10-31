import SwiftUI
import StreamCore
import class StreamCore.LibraryItem

struct MoviesTab: View {
    let library: LibraryModel

    /// One card per TMDB match (the picker lists the versions), like the Mac.
    private var movies: [LibraryItem] {
        var seen = Set<Int>()
        return library.movies.filter { $0.tmdbID.map { seen.insert($0).inserted } ?? true }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 40), count: 6), spacing: 40) {
                ForEach(movies) { item in
                    PosterCard(title: item.title.isEmpty ? item.filename : item.title,
                               posterURL: item.posterPath.map { TMDB.imageURL(path: $0, width: 342) },
                               ref: .libraryMovie(item))
                }
            }
            .padding(60)
            if !library.unmatched.isEmpty {
                PosterRow(title: "Other files", items: library.unmatched) { item in
                    PosterCard(title: item.filename, posterURL: nil, ref: .libraryMovie(item))
                }
                .padding(.bottom, 60)
            }
        }
    }
}
