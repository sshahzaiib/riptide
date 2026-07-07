import SwiftUI
import StreamCore
import class StreamCore.LibraryItem

struct ItemDetailView: View {
    @Environment(LibraryModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let item: LibraryItem
    @State private var busy = false
    @State private var playError: String?
    @State private var details: TMDBMovieDetails?
    @State private var cast: [TMDBCastMember] = []

    private var resumePosition: Double? {
        (try? model.store.continueWatching())?
            .first { $0.itemKey == item.itemKey }?.positionSeconds
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero
                CastRow(cast: cast).padding(.horizontal, 24)
            }
            .padding(.bottom, 24)
        }
        .ignoresSafeArea(edges: .top)
        .navigationTitle(item.title)
        .task {
            let token = AppSettings.shared.tmdbToken
            guard let tmdbID = item.tmdbID, item.mediaKind == "movie",
                  !token.isEmpty else { return }
            let tmdb = TMDBClient(bearerToken: token)
            details = try? await tmdb.movieDetails(id: tmdbID)
            cast = (try? await tmdb.movieCredits(id: tmdbID)) ?? []
        }
    }

    @ViewBuilder
    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            AsyncImage(url: (details?.backdropPath ?? item.posterPath).map {
                TMDB.imageURL(path: $0, width: 1280)
            }) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(.quaternary)
            }
            .frame(height: 380)
            .frame(maxWidth: .infinity)
            .clipped()
            .overlay {
                LinearGradient(colors: [.clear, .clear, .black.opacity(0.85)],
                               startPoint: .top, endPoint: .bottom)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(details?.title ?? item.title)
                    .font(.system(size: 34, weight: .bold))
                HStack(spacing: 12) {
                    if let year = item.year { Text(String(year)) }
                    if let runtime = details?.runtime { Text("\(runtime) min") }
                    if let quality = item.quality { Text(quality.uppercased()) }
                    if let rating = details?.voteAverage ?? item.rating {
                        Label(String(format: "%.1f", rating), systemImage: "star.fill")
                            .foregroundStyle(.yellow)
                    }
                }
                .foregroundStyle(.secondary)

                if let overview = details?.overview ?? item.overview, !overview.isEmpty {
                    Text(overview).lineLimit(4)
                        .frame(maxWidth: 640, alignment: .leading)
                }

                HStack(spacing: 12) {
                    Button(action: { Task { await play(resume: resumePosition != nil) } }) {
                        HStack {
                            if busy { ProgressView().controlSize(.small) }
                            else { Image(systemName: "play.fill") }
                            if let resume = resumePosition {
                                Text("Resume · \(format(resume))")
                            } else {
                                Text("Play")
                            }
                        }
                        .padding(.horizontal, 20).padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || item.link.isEmpty)

                    if let playError {
                        Text(playError).foregroundStyle(.red).font(.callout)
                    }
                }
            }
            .padding(24)
        }
    }

    private func play(resume: Bool) async {
        playError = nil
        busy = true
        defer { busy = false }
        do {
            let playItem = try await model.playItem(for: item, autoResume: resume)
            openWindow(value: playItem)
        } catch {
            playError = "Could not start stream: \(error)"
        }
    }

    private func format(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct ShowDetailView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(\.openWindow) private var openWindow
    let show: ShowGroup

    @State private var model: ShowPageModel?
    @State private var busy = false
    @State private var playError: String?

    var body: some View {
        ScrollView {
            if let model {
                VStack(alignment: .leading, spacing: 24) {
                    hero(model)
                    ForEach(model.seasons, id: \.number) { season in
                        seasonStrip(model, season: season.number, episodes: season.episodes)
                    }
                    CastRow(cast: model.cast)
                        .padding(.horizontal, 24)
                }
                .padding(.bottom, 24)
            }
        }
        .ignoresSafeArea(edges: .top)
        .navigationTitle(show.title)
        .task {
            let pageModel = ShowPageModel(show: show, store: library.store)
            model = pageModel
            let token = AppSettings.shared.tmdbToken
            guard !token.isEmpty else { return }
            await pageModel.load(tmdb: TMDBClient(bearerToken: token))
        }
    }

    // MARK: Hero

    @ViewBuilder
    private func hero(_ model: ShowPageModel) -> some View {
        ZStack(alignment: .bottomLeading) {
            AsyncImage(url: (model.details?.backdropPath ?? show.posterPath).map {
                TMDB.imageURL(path: $0, width: 1280)
            }) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(.quaternary)
            }
            .frame(height: 380)
            .frame(maxWidth: .infinity)
            .clipped()
            .overlay {
                LinearGradient(colors: [.clear, .clear, .black.opacity(0.85)],
                               startPoint: .top, endPoint: .bottom)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(model.details?.name ?? show.title)
                    .font(.system(size: 34, weight: .bold))
                HStack(spacing: 12) {
                    if let year = (model.details?.firstAirDate).flatMap({ $0.prefix(4) }) {
                        Text(String(year))
                    }
                    if let rating = model.details?.voteAverage
                        ?? show.episodes.compactMap(\.rating).first {
                        Label(String(format: "%.1f", rating), systemImage: "star.fill")
                            .foregroundStyle(.yellow)
                    }
                }
                .foregroundStyle(.secondary)

                selectedInfo(model)

                HStack(spacing: 12) {
                    playButton(model)
                    if let playError {
                        Text(playError).foregroundStyle(.red).font(.callout)
                    }
                }
            }
            .padding(24)
        }
    }

    @ViewBuilder
    private func selectedInfo(_ model: ShowPageModel) -> some View {
        if let item = model.selected {
            let meta = model.episodeMeta(for: item)
            VStack(alignment: .leading, spacing: 4) {
                Text("S\(item.season ?? 0) · E\(item.episode ?? 0)\(meta.map { " — \($0.name)" } ?? "")")
                    .font(.title3.weight(.semibold))
                HStack(spacing: 12) {
                    if let runtime = meta?.runtime { Text("\(runtime) min") }
                    if let air = meta?.airDate { Text(air) }
                    if let quality = item.quality { Text(quality.uppercased()) }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                if let overview = meta?.overview, !overview.isEmpty {
                    Text(overview)
                        .lineLimit(3)
                        .frame(maxWidth: 640, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private func playButton(_ model: ShowPageModel) -> some View {
        let resume = model.resumeTarget
        let isResumingSelected = resume?.item.itemKey == model.selected?.itemKey
        Button(action: { Task { await play(model, resume: isResumingSelected) } }) {
            HStack {
                if busy { ProgressView().controlSize(.small) }
                else { Image(systemName: "play.fill") }
                if let resume, isResumingSelected {
                    Text("Resume · \(format(resume.position))")
                } else {
                    Text("Play")
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .disabled(busy || model.selected == nil)
    }

    // MARK: Season strips

    @ViewBuilder
    private func seasonStrip(_ model: ShowPageModel, season: Int,
                             episodes: [LibraryItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(season == 0 ? "Specials" : "Season \(season)")
                .font(.title3.bold())
                .padding(.horizontal, 24)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(episodes, id: \.itemKey) { episode in
                        episodeCard(model, episode: episode)
                    }
                }
                .padding(.horizontal, 24)
            }
        }
    }

    @ViewBuilder
    private func episodeCard(_ model: ShowPageModel, episode: LibraryItem) -> some View {
        let meta = model.episodeMeta(for: episode)
        let state = model.watchState(for: episode)
        let isSelected = model.selected?.itemKey == episode.itemKey

        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                AsyncImage(url: meta?.stillPath.map { TMDB.imageURL(path: $0, width: 300) }) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        Text("E\(episode.episode ?? 0)")
                            .font(.title2.bold()).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 200, height: 112)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                if let state {
                    if state.finished {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.white, .green)
                            .padding(6)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    } else if state.progress > 0 {
                        GeometryReader { geo in
                            Rectangle().fill(.orange)
                                .frame(width: geo.size.width * state.progress, height: 3)
                        }
                        .frame(height: 3)
                    }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.orange : .clear, lineWidth: 2)
            }

            Text("\(episode.episode ?? 0). \(meta?.name ?? episode.filename)")
                .font(.caption)
                .lineLimit(1)
                .frame(width: 200, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selected = episode }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            model.selected = episode
            Task { await play(model, resume: false) }
        })
    }

    // MARK: Actions

    private func play(_ model: ShowPageModel, resume: Bool) async {
        guard let item = model.selected else { return }
        playError = nil
        busy = true
        defer { busy = false }
        do {
            let playItem = try await library.playItem(for: item, autoResume: resume)
            openWindow(value: playItem)
        } catch {
            playError = "Could not start stream: \(error)"
        }
    }

    private func format(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}
