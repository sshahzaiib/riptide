import SwiftUI
import StreamCore

struct WatchlistView: View {
    private let model = WatchlistModel.shared
    @Environment(LibraryModel.self) private var library

    private let posterColumns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 16)]

    var body: some View {
        Group {
            switch model.state {
            case .failed:
                VStack(spacing: 8) {
                    Text("Couldn't load your watchlist").foregroundStyle(.secondary)
                    Button("Retry") { Task { await model.load() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loading where model.items.isEmpty:
                skeletonGrid
            default:
                grid
            }
        }
        .navigationTitle("Watchlist")
        .task { await model.load() }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: posterColumns, spacing: 20) {
                ForEach(model.items) { media in
                    NavigationLink(destination: DiscoverDestination(media: media, library: library)) {
                        PosterCard(title: media.title,
                                   subtitle: media.year.map(String.init),
                                   posterPath: media.posterPath)
                            .overlay(alignment: .topTrailing) {
                                if library.hasLibraryEntry(tmdbID: media.tmdbID, isShow: media.isShow) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .green)
                                        .padding(6)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Remove from Watchlist") {
                            Task { await model.toggle(media) }
                        }
                    }
                }
            }
            .padding()
        }
        .overlay {
            if model.items.isEmpty && model.state == .loaded {
                ContentUnavailableView("Watchlist is empty",
                                       systemImage: "bookmark",
                                       description: Text("Search for a title and add it to your watchlist."))
            }
        }
    }

    private var skeletonGrid: some View {
        ScrollView {
            LazyVGrid(columns: posterColumns, spacing: 20) {
                ForEach(0..<12, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.quaternary)
                        .frame(height: 240)
                }
            }
            .padding()
        }
    }
}
