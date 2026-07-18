import SwiftUI
import StreamCore
import class StreamCore.LibraryItem

struct ItemDetailView: View {
    @Environment(LibraryModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL
    let item: LibraryItem
    @State private var busy = false
    @State private var playError: String?
    @State private var details: TMDBMovieDetails?
    @State private var cast: [TMDBCastMember] = []
    @State private var streamRequest: StreamRequest?
    @State private var imdbID: String?

    /// All library copies of this movie, preference-ranked. Unmatched items
    /// (tmdbID nil) can't be correlated — they stay single-version.
    // ponytail: inline store fetch per body eval, same idiom as resumePosition
    // above; the WatchState table is tiny. Cache in @State if it ever shows up
    // in a profile.
    private var versions: [LibraryItem] {
        guard let tmdbID = item.tmdbID else { return [item] }
        let copies = model.items.filter { $0.tmdbID == tmdbID && $0.mediaKind == "movie" }
        guard copies.count > 1 else { return [item] }
        let states = Dictionary(
            ((try? model.store.allWatchStates()) ?? []).map { ($0.itemKey, $0) },
            uniquingKeysWith: { first, _ in first })
        return VersionPreference.ranked(items: copies, states: states)
    }
    private var current: LibraryItem { versions.first ?? item }

    private var resumePosition: Double? {
        (try? model.store.continueWatching())?
            .first { $0.itemKey == current.itemKey }?.positionSeconds
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
        .sheet(item: $streamRequest) { request in
            StreamPickerSheet(request: request)
        }
        .task {
            let token = AppSettings.shared.tmdbToken
            guard let tmdbID = item.tmdbID, item.mediaKind == "movie",
                  !token.isEmpty else { return }
            let tmdb = TMDBClient(bearerToken: token)
            details = try? await tmdb.movieDetails(id: tmdbID)
            cast = (try? await tmdb.movieCredits(id: tmdbID)) ?? []
            imdbID = (try? await tmdb.externalIDs(movieID: tmdbID))?.imdbID
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
                    if let quality = current.quality { Text(quality.uppercased()) }
                    ServiceBadge(service: current.service)
                    if let rating = details?.voteAverage ?? item.rating {
                        Label(String(format: "%.1f", rating), systemImage: "star.fill")
                            .foregroundStyle(.yellow)
                    }
                    if let tmdbID = item.tmdbID, item.mediaKind == "movie" {
                        TraktRatingMenu(media: .movie(tmdbID: tmdbID))
                    }
                }
                .foregroundStyle(.secondary)

                if let overview = details?.overview ?? item.overview, !overview.isEmpty {
                    Text(overview).lineLimit(4)
                        .frame(maxWidth: 640, alignment: .leading)
                }

                Text("\(current.service.uppercased()) · \(current.filename)")
                    .font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle).frame(maxWidth: 640, alignment: .leading)

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
                    .disabled(busy || current.link.isEmpty)

                    if versions.count > 1 {
                        Menu {
                            ForEach(versions, id: \.itemKey) { version in
                                Button {
                                    Task { await play(resume: false, version: version) }
                                } label: {
                                    Text(versionLabel(version,
                                                      isPreferred: version.itemKey == current.itemKey))
                                }
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .buttonStyle(.bordered)
                        .fixedSize()
                        .help("\(versions.count) versions in your library")
                    }

                    Button { findStreams() } label: {
                        Label("Find Streams", systemImage: "magnifyingglass")
                            .padding(.horizontal, 12).padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .disabled(imdbID == nil)
                    .help(imdbID == nil
                          ? "No IMDb match for this movie yet — addons can't be searched."
                          : "Search your addons for a different stream")

                    if versions.count > 1 {
                        Menu {
                            ForEach(versions, id: \.itemKey) { version in
                                Button {
                                    Task { await download(version) }
                                } label: {
                                    Text(versionLabel(version,
                                                      isPreferred: version.itemKey == current.itemKey))
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.down.circle")
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.bordered)
                        .fixedSize()
                        .disabled(busy || current.link.isEmpty)
                        .help("Download a version in your browser")
                    } else {
                        Button { Task { await download() } } label: {
                            Image(systemName: "arrow.down.circle")
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.bordered)
                        .disabled(busy || current.link.isEmpty)
                        .help("Open the direct download link in your browser")
                    }

                    if let playError {
                        Text(playError).foregroundStyle(.red).font(.callout)
                    }
                }
            }
            .padding(24)
        }
    }

    private func play(resume: Bool, version: LibraryItem? = nil) async {
        playError = nil
        busy = true
        defer { busy = false }
        do {
            let playItem = try await model.playItem(for: version ?? current, autoResume: resume)
            openWindow(value: playItem)
        } catch {
            playError = "Could not start stream: \(error)"
        }
    }

    /// Resolve the file's direct debrid URL and hand it to the browser to download.
    private func download(_ version: LibraryItem? = nil) async {
        playError = nil
        busy = true
        defer { busy = false }
        do {
            let playItem = try await model.playItem(for: version ?? current)
            openURL(playItem.url)
        } catch {
            playError = "Could not get download link: \(error)"
        }
    }

    private func findStreams() {
        guard let imdbID, let tmdbID = item.tmdbID else { return }
        streamRequest = StreamRequest(type: .movie,
                                      imdbID: imdbID,
                                      title: item.title,
                                      season: nil,
                                      episode: nil,
                                      tmdbID: tmdbID)
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
    @Environment(\.openURL) private var openURL
    let show: ShowGroup

    @State private var model: ShowPageModel?
    @State private var busy = false
    @State private var playError: String?
    @State private var streamRequest: StreamRequest?

    var body: some View {
        ScrollView {
            if let model {
                VStack(alignment: .leading, spacing: 24) {
                    hero(model)
                    ForEach(model.seasonSlots, id: \.number) { season in
                        seasonStrip(model, season: season.number, slots: season.slots)
                    }
                    CastRow(cast: model.cast)
                        .padding(.horizontal, 24)
                }
                .padding(.bottom, 24)
            }
        }
        .ignoresSafeArea(edges: .top)
        .navigationTitle(show.title)
        .sheet(item: $streamRequest) { request in
            StreamPickerSheet(request: request)
        }
        .task {
            let pageModel = ShowPageModel(show: show, store: library.store)
            model = pageModel
            let token = AppSettings.shared.tmdbToken
            guard !token.isEmpty else { return }
            await pageModel.load(tmdb: TMDBClient(bearerToken: token))
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didBecomeKeyNotification)) { _ in
            // Player window closed / library window refocused: refresh progress badges.
            model?.refreshWatchStates()
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
                    if let showID = model.showID {
                        TraktRatingMenu(media: .show(tmdbID: showID))
                    }
                }
                .foregroundStyle(.secondary)

                selectedInfo(model)

                HStack(spacing: 12) {
                    playButton(model)
                    findStreamsButton(model)
                    downloadButton(model)
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
                    ServiceBadge(service: item.service)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                if let overview = meta?.overview, !overview.isEmpty {
                    Text(overview)
                        .lineLimit(3)
                        .frame(maxWidth: 640, alignment: .leading)
                }

                Text("\(item.service.uppercased()) · \(item.filename)")
                    .font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle).frame(maxWidth: 640, alignment: .leading)
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
                    if let s = resume.item.season, let e = resume.item.episode {
                        Text("Resume S\(s)E\(e) · \(format(resume.position))")
                    } else {
                        Text("Resume · \(format(resume.position))")
                    }
                } else if let s = model.selected?.season, let e = model.selected?.episode {
                    Text("Play S\(s)E\(e)")
                } else {
                    Text("Play")
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .disabled(busy || model.selected == nil)
    }

    /// Secondary action: grab an alternate stream for the selected episode
    /// (wrong language, no subs, bad quality).
    @ViewBuilder
    private func findStreamsButton(_ model: ShowPageModel) -> some View {
        let selected = model.selected
        let searchable = model.imdbID != nil
            && selected?.season != nil && selected?.episode != nil
        Button {
            guard let season = selected?.season, let episode = selected?.episode else { return }
            findStreams(model, season: season, episode: episode)
        } label: {
            Label("Find Streams", systemImage: "magnifyingglass")
                .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
        .disabled(!searchable)
        .help(searchable
              ? "Search your addons for a different stream of the selected episode"
              : (model.imdbID == nil
                 ? "No IMDb match for this show yet — addons can't be searched."
                 : "Select an episode first to find alternate streams."))
    }

    /// Open the selected episode's direct debrid URL in the browser to download.
    /// When the episode has multiple owned files, offer a version picker.
    @ViewBuilder
    private func downloadButton(_ model: ShowPageModel) -> some View {
        let versions = model.selected.map { model.versions(of: $0) } ?? []
        if versions.count > 1 {
            Menu {
                ForEach(versions, id: \.itemKey) { version in
                    Button {
                        Task { await download(model, version: version) }
                    } label: {
                        Text(versionLabel(version,
                                          isPreferred: version.itemKey == versions.first?.itemKey))
                    }
                }
            } label: {
                Image(systemName: "arrow.down.circle")
                    .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
            .fixedSize()
            .disabled(busy)
            .help("Download a version of the selected episode in your browser")
        } else {
            Button { Task { await download(model) } } label: {
                Image(systemName: "arrow.down.circle")
                    .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
            .disabled(busy || model.selected == nil)
            .help("Open the direct download link for the selected episode in your browser")
        }
    }

    // MARK: Season strips

    @ViewBuilder
    private func seasonStrip(_ model: ShowPageModel, season: Int,
                             slots: [ShowPageModel.EpisodeSlot]) -> some View {
        let owned = slots.compactMap(\.item)
        VStack(alignment: .leading, spacing: 10) {
            Text(season == 0 ? "Specials" : "Season \(season)")
                .font(.title3.bold())
                .padding(.horizontal, 24)
                .contextMenu {
                    if !owned.isEmpty {
                        Button("Mark Season Watched") { model.setWatched(true, items: owned) }
                        Button("Mark Season Unwatched") { model.setWatched(false, items: owned) }
                    }
                }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(slots) { slot in
                        if slot.items.isEmpty {
                            missingEpisodeCard(model, slot: slot)
                        } else {
                            episodeCard(model, slot: slot)
                        }
                    }
                }
                .padding(.horizontal, 24)
            }
        }
    }

    /// Episode we don't have a file for: dimmed TMDB still + Find Streams.
    @ViewBuilder
    private func missingEpisodeCard(_ model: ShowPageModel,
                                    slot: ShowPageModel.EpisodeSlot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                AsyncImage(url: slot.meta?.stillPath.map {
                    TMDB.imageURL(path: $0, width: 300)
                }) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        Text("E\(slot.number)")
                            .font(.title2.bold()).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 200, height: 112)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .opacity(0.55)

                Image(systemName: "magnifyingglass")
                    .font(.title3)
                    .padding(8)
                    .background(.ultraThinMaterial, in: Circle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

                if let state = model.remoteState(season: slot.season, episode: slot.number) {
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
            .frame(width: 200, height: 112)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text("\(slot.number). \(slot.meta?.name ?? "Episode \(slot.number)")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 200, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture { findStreams(model, season: slot.season, episode: slot.number) }
    }

    @ViewBuilder
    private func episodeCard(_ model: ShowPageModel, slot: ShowPageModel.EpisodeSlot) -> some View {
        if let episode = slot.item {   // preferred version
            let meta = model.episodeMeta(for: episode)
            let state = model.watchState(for: episode)
            let isSelected = slot.items.contains { $0.itemKey == model.selected?.itemKey }

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

                    if slot.items.count > 1 {
                        Text("\(slot.items.count) versions")
                            .font(.caption2.bold())
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(6)
                            .frame(maxWidth: .infinity, maxHeight: .infinity,
                                   alignment: .topLeading)
                    }

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
            .contextMenu {
                Button(model.isFinished(episode) ? "Mark Unwatched" : "Mark Watched") {
                    model.setWatched(!model.isFinished(episode), items: [episode])
                }
                if slot.items.count > 1 {
                    Menu("Versions") {
                        ForEach(slot.items, id: \.itemKey) { version in
                            Button {
                                model.userDidSelect(version)
                                Task { await play(model, resume: false) }
                            } label: {
                                Text(versionLabel(version,
                                                  isPreferred: version.itemKey == episode.itemKey))
                            }
                        }
                    }
                }
                if episode.season != nil && episode.episode != nil {
                    Button("Find Other Streams…") {
                        findStreams(model, season: slot.season, episode: slot.number)
                    }
                }
            }
            .onTapGesture { model.userDidSelect(episode) }
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                model.userDidSelect(episode)
                Task { await play(model, resume: false) }
            })
        }
    }

    // MARK: Actions

    private func findStreams(_ model: ShowPageModel, season: Int, episode: Int) {
        guard let imdbID = model.imdbID, let showID = model.showID else {
            playError = "This show can't be searched on addons yet."
            return
        }
        playError = nil
        streamRequest = StreamRequest(type: .series,
                                      imdbID: imdbID,
                                      title: show.title,
                                      season: season,
                                      episode: episode,
                                      tmdbID: showID)
    }

    private func download(_ model: ShowPageModel, version: LibraryItem? = nil) async {
        guard let item = version ?? model.selected else { return }
        playError = nil
        busy = true
        defer { busy = false }
        do {
            let playItem = try await library.playItem(for: item)
            openURL(playItem.url)
        } catch {
            playError = "Could not get download link: \(error)"
        }
    }

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

/// "✓ 2160P · RD · Show.S01E01.2160p.WEB…" — quality · service · trimmed name.
func versionLabel(_ version: LibraryItem, isPreferred: Bool) -> String {
    let label = [version.quality?.uppercased() ?? "?",
                 version.service.uppercased(),
                 String(version.filename.prefix(40))]
        .joined(separator: " · ")
    return isPreferred ? "✓ " + label : label
}
