import SwiftUI
import StreamCore
import class StreamCore.LibraryItem

/// Full-grid "See All" destination for the Discover Up Next shelf. Same
/// routing as the shelf: in-library episode/movie plays directly (resuming
/// from local WatchState), everything else goes to the detail/add flow.
struct UpNextView: View {
    private let model = UpNextModel.shared
    @Environment(LibraryModel.self) private var library
    @Environment(\.openWindow) private var openWindow
    @State private var playError: String?

    private let posterColumns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 16)]

    var body: some View {
        Group {
            switch model.state {
            case .failed:
                VStack(spacing: 8) {
                    Text("Couldn't load Up Next").foregroundStyle(.secondary)
                    Button("Retry") { Task { await model.load() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .idle,
                 .loading where model.entries.isEmpty:
                skeletonGrid
            default:
                grid
            }
        }
        .navigationTitle("Up Next")
        .task { await model.load() }
    }

    private var grid: some View {
        ScrollView {
            if let err = playError {
                Text(err).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }
            LazyVGrid(columns: posterColumns, spacing: 20) {
                ForEach(model.entries) { entry in
                    Group {
                        if let libItem = library.observedLibraryItem(tmdbID: entry.item.tmdbID,
                                                                    season: entry.item.season,
                                                                    episode: entry.item.number) {
                            Button {
                                Task { await play(libItem) }
                            } label: {
                                card(entry)
                            }
                        } else {
                            NavigationLink(destination: DiscoverDestination(media: entry.media,
                                                                            library: library)) {
                                card(entry)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if TraktService.shared.isConnected {
                            let on = WatchlistModel.shared.isOnWatchlist(entry.media)
                            Button(on ? "Remove from Watchlist" : "Add to Watchlist") {
                                Task { await WatchlistModel.shared.toggle(entry.media) }
                            }
                            let fav = FavoritesModel.shared.isFavorite(entry.media)
                            Button(fav ? "Remove from Favorites" : "Add to Favorites") {
                                Task { await FavoritesModel.shared.toggle(entry.media) }
                            }
                        }
                    }
                }
            }
            .padding()
            if model.hasMore {
                Button {
                    Task { await model.loadMore() }
                } label: {
                    if model.isLoadingMore {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Show More")
                    }
                }
                .disabled(model.isLoadingMore)
                .padding(.bottom)
            }
        }
        .overlay {
            if model.entries.isEmpty && model.state == .loaded {
                ContentUnavailableView("Nothing up next",
                                       systemImage: "play.rectangle.on.rectangle",
                                       description: Text("Shows you're partway through on Trakt will appear here."))
            }
        }
    }

    private func card(_ entry: UpNextModel.Entry) -> some View {
        PosterCard(title: entry.media.title,
                   subtitle: entry.subtitle.isEmpty ? entry.media.year.map(String.init) : entry.subtitle,
                   posterPath: entry.media.posterPath)
            .overlay(alignment: .topTrailing) {
                if library.hasLibraryEntry(tmdbID: entry.media.tmdbID, isShow: entry.media.isShow) {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .green)
                        .padding(6)
                }
            }
    }

    private func play(_ item: LibraryItem) async {
        playError = nil
        do {
            let playItem = try await library.playItem(for: item, autoResume: true)
            openWindow(value: playItem)
        } catch {
            playError = "Could not start stream: \(error.localizedDescription)"
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
