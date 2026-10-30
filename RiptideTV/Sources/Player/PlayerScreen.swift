import SwiftUI
import StreamCore
import class StreamCore.LibraryItem

struct PlayerScreen: View {
    @State private var item: PlayItem
    @State private var model: PlayerModel
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var closed = false
    @State private var sheet: Sheet?
    @Environment(\.dismiss) private var dismiss

    enum Sheet: String, Identifiable { case audio, subtitles, more; var id: String { rawValue } }

    init(item: PlayItem) {
        _item = State(initialValue: item)
        _model = State(initialValue: PlayerModel(store: AppModels.store, itemKey: item.itemKey,
                                                 traktMedia: TraktMedia(playItem: item)))
    }

    private var store: LibraryStore { AppModels.store }
    private var isAddon: Bool { item.itemKey.hasPrefix("addon#") }
    private var prevEpisode: LibraryItem? { isAddon ? nil : try? store.previousEpisode(before: item.itemKey) }
    private var nextEpisode: LibraryItem? { isAddon ? nil : try? store.nextEpisode(after: item.itemKey) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            MPVHostView(model: model, item: item).ignoresSafeArea()
            if !controlsVisible {
                Color.clear.focusable().onMoveCommand { _ in showControls() }
            }
            if controlsVisible {
                ControlsOverlay(model: model, item: item,
                                hasPrev: prevEpisode != nil, hasNext: nextEpisode != nil,
                                onPrev: { go(prevEpisode) }, onNext: { go(nextEpisode) },
                                onAudio: { sheet = .audio }, onSubs: { sheet = .subtitles },
                                onMore: { sheet = .more }, onInput: showControls)
            }
            if let err = model.playbackError {
                VStack(spacing: 24) {
                    Text(err)
                    Button("Close") { close() }
                }.padding(60).background(.black.opacity(0.85))
            }
        }
        .onPlayPauseCommand { model.togglePause(); showControls() }
        .onExitCommand { controlsVisible ? hide() : close() }
        .sheet(item: $sheet) { s in
            switch s {
            case .audio: TrackPicker(kind: .audio, model: model, item: item)
            case .subtitles: TrackPicker(kind: .subtitles, model: model, item: item)
            case .more: MoreSheet(model: model)
            }
        }
        .onChange(of: model.ended) { _, ended in
            guard ended else { return }
            if let next = nextEpisode { go(next) } else { close() }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            showControls()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            hideTask?.cancel()
            shutdownOnce()
        }
    }

    private func hide() { hideTask?.cancel(); controlsVisible = false }

    private func showControls() {
        controlsVisible = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled && sheet == nil { controlsVisible = false }
        }
    }

    private func go(_ episode: LibraryItem?) {
        guard let episode else { return }
        Task {
            guard let next = try? await PlayItemBuilder.make(for: episode, store: store) else { return }
            item = next
            model.advance(to: next)   // reloads on the same controller
            showControls()
        }
    }

    private func shutdownOnce() {
        guard !closed else { return }
        closed = true
        model.shutdown()
    }

    private func close() { shutdownOnce(); dismiss() }
}
