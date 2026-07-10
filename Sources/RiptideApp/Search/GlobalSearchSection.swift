import SwiftUI
import StreamCore

/// "From TMDB" shelf appended under the local library grids while the
/// toolbar search has text. Debounces 400 ms, then queries TMDB.
struct GlobalSearchSection: View {
    enum Kind { case movies, shows }
    let kind: Kind

    @Environment(LibraryModel.self) private var model
    @State private var search = GlobalSearchModel()

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 16)]

    private var results: [SearchMedia] {
        switch kind {
        case .movies: search.movies.map { .movie($0) }
        case .shows: search.shows.map { .show($0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !results.isEmpty {
                Text("From TMDB")
                    .font(.title2.bold())
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(results) { media in
                        NavigationLink(destination: SearchDetailView(media: media)) {
                            PosterCard(title: media.title,
                                       subtitle: media.year.map(String.init),
                                       posterPath: media.posterPath)
                                .overlay(alignment: .topTrailing) {
                                    if model.hasLibraryEntry(tmdbID: media.tmdbID) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.title3)
                                            .foregroundStyle(.white, .green)
                                            .padding(6)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else if search.searching {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            }
        }
        .padding(.horizontal)
        .padding(.bottom)
        .task(id: model.searchText) {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await search.search(query: model.searchText)
        }
    }
}
