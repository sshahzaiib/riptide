import SwiftUI
import StreamCore

struct SearchTab: View {
    @State private var model = GlobalSearchModel()
    @State private var query = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                if query.trimmingCharacters(in: .whitespaces).count < 2 {
                    Text("Search for movies and TV shows")
                        .font(.title3).foregroundStyle(.secondary).padding(.top, 200)
                } else {
                    VStack(alignment: .leading, spacing: 40) {
                        row("Movies", model.movies.map(SearchMedia.movie))
                        row("Shows", model.shows.map(SearchMedia.show))
                    }
                }
            }
            .navigationDestination(for: TitleRef.self) { TitlePage(ref: $0) }
            .searchable(text: $query)
            .task(id: query) {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                await model.search(query: query)
            }
        }
    }

    @ViewBuilder
    private func row(_ title: String, _ items: [SearchMedia]) -> some View {
        if !items.isEmpty {
            PosterRow(title: title, items: items) { media in
                PosterCard(title: media.title,
                           posterURL: media.posterPath.map { TMDB.imageURL(path: $0, width: 342) }, ref: .media(media))
                .frame(width: 220)
            }
        }
    }
}
