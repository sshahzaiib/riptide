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
                if model.ref.isShow { seasons; EpisodeList(rows: model.rows) { run($0) } }
            }
            .padding(60)
        }
        .overlay { if busy { ProgressView().scaleEffect(2) } }
        .task {
            await model.load()
            if openVersionsOnLoad { run(nil, forcePicker: true) }
        }
        .onChange(of: model.season) { Task { await model.loadSeason() } }
        .sheet(item: $picker, onDismiss: { playItem = pendingPlay; pendingPlay = nil }) { ctx in
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
        HStack(spacing: 30) {
            Button { run(model.ref.isShow ? model.playTarget : nil) } label: {
                Label("Play", systemImage: "play.fill").font(.title3.bold()).padding(.horizontal, 40)
            }
            .buttonStyle(.borderedProminent)
            Button("Other versions") { run(model.ref.isShow ? model.playTarget : nil, forcePicker: true) }
        }
        .disabled(busy)
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
    private func run(_ row: EpisodeRow?, forcePicker: Bool = false) {
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                let isShow = model.ref.isShow
                let items = isShow ? (row?.items ?? []) : model.movieItems
                let outcome = try await model.resolve(
                    items: items, season: isShow ? row?.season : nil,
                    episode: isShow ? row?.number : nil,
                    forcePicker: forcePicker, alwaysShow: alwaysShowVersions)
                switch outcome {
                case .play(let item): playItem = item; PlayResolver.refreshLibraryLater(for: item)
                case .picker(let ctx): picker = ctx
                }
            } catch { self.error = error.localizedDescription }
        }
    }
}
