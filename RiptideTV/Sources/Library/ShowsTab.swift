import SwiftUI
import StreamCore

struct ShowsTab: View {
    let library: LibraryModel

    var body: some View {
        PosterGrid(items: library.shows) { show in
            PosterCard(title: show.title,
                       posterURL: show.posterPath.map { TMDB.imageURL(path: $0, width: 342) }, ref: .libraryShow(show))
        }
    }
}
