import SwiftUI
import StreamCore

struct TitlePage: View {
    @State private var model: TitleModel
    var openVersionsOnLoad = false      // debug hook only
    @AppStorage("alwaysShowVersions") private var alwaysShowVersions = false
    @State private var playItem: PlayItem?
    @State private var picker: PickerContext?
    @State private var pendingPlay: PlayItem?
    @State private var busy = false
    @State private var error: String?
    @State private var runTask: Task<Void, Never>?

    init(ref: TitleRef, openVersionsOnLoad: Bool = false) {
        _model = State(initialValue: TitleModel(ref: ref))
        self.openVersionsOnLoad = openVersionsOnLoad
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                header
                buttons
                if let error { Text(error).foregroundStyle(.red) }
                if model.ref.isShow { seasons; EpisodeList(rows: model.rows) { run($0, start: $1) } }
            }
            .padding(60)
        }
        .overlay { if busy { ProgressView().scaleEffect(2) } }
        .task {
            await model.load()
            if openVersionsOnLoad { run(nil, forcePicker: true) }
        }
        .onChange(of: playItem) { if playItem == nil { model.refreshWatchStates() } }
        .onChange(of: model.season) { Task { await model.loadSeason() } }
        .onDisappear { runTask?.cancel() }
        .sheet(item: $picker, onDismiss: {
            if let item = pendingPlay { playItem = item; PlayResolver.refreshLibraryLater(for: item) }
            pendingPlay = nil
        }) { ctx in
            VersionPicker(libraryItems: ctx.items, request: ctx.request) { item in
                pendingPlay = item
                picker = nil
            }
        }
        .fullScreenCover(item: $playItem) { PlayerScreen(item: $0) }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 50) {
            let path = model.backdropPath ?? model.ref.posterPath
            AsyncImage(url: path.map { TMDB.imageURL(path: $0, width: 780) }) { $0.resizable().scaledToFill() }
                placeholder: { Rectangle().fill(Color(white: 0.12)) }
                .frame(width: 780, height: 440).clipped().clipShape(RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 16) {
                Text(model.title).font(.largeTitle.bold())
                if let year = model.ref.year { Text(String(year)).foregroundStyle(.secondary) }
                Text(model.overview).lineLimit(4).foregroundStyle(.secondary)
            }
        }
    }

    private var buttons: some View {
        let target = model.ref.isShow ? model.playTarget : nil
        let resume = model.resumeState(for: target)
        let episode = target.map { "S\($0.season) E\($0.number)" + ($0.name.isEmpty ? "" : " · \($0.name)") }
        return HStack(spacing: 30) {
            if let resume {
                Button { run(target, start: .resume) } label: {
                    VStack(spacing: 6) {
                        Label("Resume", systemImage: "play.fill").font(.title3.bold())
                        Text([episode, timeLeft(resume)].compactMap { $0 }.joined(separator: " · "))
                            .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }.padding(.horizontal, 40)
                }
                .buttonStyle(.borderedProminent)
                Button("Play from start") { run(target, start: .fromStart) }
            } else {
                Button { run(target) } label: {
                    Label(episode.map { "Play \($0)" } ?? "Play", systemImage: "play.fill")
                        .font(.title3.bold()).lineLimit(1).padding(.horizontal, 40)
                }
                .buttonStyle(.borderedProminent)
            }
            Button("Other versions") { run(target, forcePicker: true) }
        }
        .disabled(busy)
    }

    private func timeLeft(_ s: WatchState) -> String {
        let pos = s.positionSeconds, dur = s.durationSeconds
        guard dur > 0 else { let t = Int(pos); return String(format: "from %d:%02d", t / 60, t % 60) }
        let m = Int(((dur - pos) / 60).rounded())
        return m >= 60 ? "\(m / 60) h \(m % 60) min left" : "\(max(m, 1)) min left"
    }

    private var seasons: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(model.seasonNumbers, id: \.self) { n in
                    Button(n == 0 ? "Specials" : "Season \(n)") { model.season = n }
                        .buttonStyle(.bordered).opacity(n == model.season ? 1 : 0.6)
                }
            }.padding(.vertical, 10)
        }
    }

    /// nil row = movie. Resolves on a task; picker/player presented from the outcome.
    private func run(_ row: EpisodeRow?, forcePicker: Bool = false, start: PlayStart = .ask) {
        busy = true; error = nil
        runTask?.cancel()
        runTask = Task {
            defer { busy = false }
            do {
                let isShow = model.ref.isShow
                let items = isShow ? (row?.items ?? []) : model.movieItems
                let outcome = try await model.resolve(
                    items: items, season: isShow ? row?.season : nil,
                    episode: isShow ? row?.number : nil,
                    forcePicker: forcePicker, alwaysShow: alwaysShowVersions)
                guard !Task.isCancelled else { return }
                switch outcome {
                case .play(let item): playItem = item.starting(start); PlayResolver.refreshLibraryLater(for: item)
                case .picker(let ctx): picker = ctx
                }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}
