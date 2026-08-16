import SwiftUI
import StreamCore
import class StreamCore.LibraryItem

/// What the stream picker needs to query addons for one movie or episode.
struct StreamRequest: Identifiable {
    let id = UUID()
    let type: StremioAddonClient.MediaType
    let imdbID: String
    let title: String
    let season: Int?
    let episode: Int?
    let tmdbID: Int
}

/// Detail page for a TMDB search result. Library-priority: anything already
/// in the library plays directly; otherwise "Find Streams" queries addons.
struct SearchDetailView: View {
    let media: SearchMedia

    @Environment(LibraryModel.self) private var library
    @Environment(\.openWindow) private var openWindow

    @State private var seasonNumbers = [1]
    @State private var season = 1
    @State private var episodes: [TMDBSeasonEpisode] = []
    @State private var imdbID: String?
    @State private var streamRequest: StreamRequest?
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
                if media.isShow {
                    showSection
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(media.title)
        .task { await loadShowIfNeeded() }
        .task { if WatchlistModel.shared.state == .idle { await WatchlistModel.shared.load() } }
        .task { if FavoritesModel.shared.state == .idle { await FavoritesModel.shared.load() } }
        .sheet(item: $streamRequest) { request in
            StreamPickerSheet(request: request)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            AsyncImage(url: media.posterPath.map { TMDB.imageURL(path: $0) }) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(.quaternary)
            }
            .frame(width: 150, height: 225)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 8) {
                Text(media.title).font(.title.bold())
                if let year = media.year {
                    Text(String(year)).foregroundStyle(.secondary)
                }
                Text(media.overview)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                if !media.isShow {
                    HStack(spacing: 12) {
                        movieAction
                        watchlistButton
                        favoriteButton
                    }
                } else {
                    HStack(spacing: 12) {
                        watchlistButton
                        favoriteButton
                    }
                }
                if let err = WatchlistModel.shared.lastError, err.id == media.id {
                    Text(err.message).font(.caption).foregroundStyle(.red)
                }
                if let err = FavoritesModel.shared.lastError, err.id == media.id {
                    Text(err.message).font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    @ViewBuilder
    private var watchlistButton: some View {
        if TraktService.shared.isConnected {
            let on = WatchlistModel.shared.isOnWatchlist(media)
            Button {
                Task { await WatchlistModel.shared.toggle(media) }
            } label: {
                Label(on ? "On Watchlist" : "Add to Watchlist",
                      systemImage: on ? "bookmark.fill" : "bookmark")
            }
            .buttonStyle(.bordered)
            .help(on ? "Remove from your Trakt watchlist" : "Add to your Trakt watchlist")
            .disabled(WatchlistModel.shared.isToggling(media))
        }
    }

    @ViewBuilder
    private var favoriteButton: some View {
        if TraktService.shared.isConnected {
            let on = FavoritesModel.shared.isFavorite(media)
            Button {
                Task { await FavoritesModel.shared.toggle(media) }
            } label: {
                Label(on ? "Favorited" : "Add to Favorites",
                      systemImage: on ? "heart.fill" : "heart")
            }
            .buttonStyle(.bordered)
            .help(on ? "Remove from your Trakt favorites (favorites tune your recommendations)"
                     : "Add to your Trakt favorites (favorites tune your recommendations)")
            .disabled(FavoritesModel.shared.isToggling(media))
        }
    }

    @ViewBuilder
    private var movieAction: some View {
        if let item = library.libraryItem(tmdbID: media.tmdbID, season: nil, episode: nil) {
            Button { play(item) } label: {
                Label("Play", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button { Task { await findStreams(season: nil, episode: nil) } } label: {
                Label("Find Streams", systemImage: "magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var showSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Season", selection: $season) {
                ForEach(seasonNumbers, id: \.self) {
                    Text($0 == 0 ? "Specials" : "Season \($0)").tag($0)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 200, alignment: .leading)

            ForEach(episodes, id: \.episodeNumber) { episode in
                episodeRow(episode)
                Divider()
            }
        }
        .task(id: season) { await loadEpisodes() }
    }

    private func episodeRow(_ episode: TMDBSeasonEpisode) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(episode.episodeNumber)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(episode.name).font(.headline)
                if !episode.overview.isEmpty {
                    Text(episode.overview).font(.caption)
                        .foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            if let item = library.libraryItem(tmdbID: media.tmdbID,
                                              season: season,
                                              episode: episode.episodeNumber) {
                Button { play(item) } label: { Label("Play", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            } else {
                Button { Task { await findStreams(season: season, episode: episode.episodeNumber) } }
                    label: { Label("Find Streams", systemImage: "magnifyingglass") }
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: actions

    private func play(_ item: LibraryItem) {
        Task {
            do { openWindow(value: try await library.playItem(for: item)) }
            catch { errorMessage = "Couldn't start playback: \(error.localizedDescription)" }
        }
    }

    private func findStreams(season: Int?, episode: Int?) async {
        errorMessage = nil
        do {
            let id = try await resolveIMDBID()
            streamRequest = StreamRequest(type: media.isShow ? .series : .movie,
                                          imdbID: id,
                                          title: media.title,
                                          season: season,
                                          episode: episode,
                                          tmdbID: media.tmdbID)
        } catch {
            errorMessage = "This title can't be searched on addons yet."
        }
    }

    private func resolveIMDBID() async throws -> String {
        if let imdbID { return imdbID }
        let tmdb = TMDBClient(bearerToken: AppSettings.shared.tmdbToken, cache: .shared)
        let ids: TMDBExternalIDs = media.isShow
            ? try await tmdb.externalIDs(showID: media.tmdbID)
            : try await tmdb.externalIDs(movieID: media.tmdbID)
        guard let id = ids.imdbID, !id.isEmpty else { throw TMDBError.badResponse }
        imdbID = id
        return id
    }

    // MARK: loading

    private func loadShowIfNeeded() async {
        guard media.isShow else { return }
        let tmdb = TMDBClient(bearerToken: AppSettings.shared.tmdbToken, cache: .shared)
        if let details = try? await tmdb.showDetails(id: media.tmdbID) {
            seasonNumbers = details.seasonNumbers
            if !seasonNumbers.contains(season) {
                season = seasonNumbers.first(where: { $0 > 0 }) ?? seasonNumbers.first ?? 1
            }
        }
    }

    private func loadEpisodes() async {
        guard media.isShow else { return }
        episodes = []   // don't render stale prior-season rows under the new season
        let tmdb = TMDBClient(bearerToken: AppSettings.shared.tmdbToken, cache: .shared)
        episodes = (try? await tmdb.seasonEpisodes(showID: media.tmdbID, season: season)) ?? []
    }
}
