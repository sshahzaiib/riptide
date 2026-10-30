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
    @State private var syncing = false
    /// Outer nil = undecided (resume prompt pending); inner nil = start from 0.
    @State private var startAt: Double??
    @State private var askResume = false
    @State private var goTask: Task<Void, Never>?
    @FocusState private var skipFocused: Bool
    @AppStorage("autoplayNext") private var autoplayNext = true
    @State private var upNextCountdown: Int?
    @State private var upNextShown = false
    @State private var upNextDismissed = false
    @State private var upNextTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    enum Sheet: String, Identifiable { case audio, subtitles, more; var id: String { rawValue } }

    init(item: PlayItem) {
        _item = State(initialValue: item)
        if let r = item.resumeFrom, r > 60 {
            if item.autoResume { _startAt = State(initialValue: .some(r)) } else { _askResume = State(initialValue: true) }
        } else {
            _startAt = State(initialValue: .some(nil))
        }
        _model = State(initialValue: PlayerModel(store: AppModels.store, itemKey: item.itemKey,
                                                 traktMedia: TraktMedia(playItem: item)))
    }

    private var store: LibraryStore { AppModels.store }
    private var isAddon: Bool { item.itemKey.hasPrefix("addon#") }
    private var prevEpisode: LibraryItem? { isAddon ? nil : try? store.previousEpisode(before: item.itemKey) }
    private var nextEpisode: LibraryItem? { isAddon ? nil : try? store.nextEpisode(after: item.itemKey) }

    private var inIntro: Bool { item.season != nil && (model.markers.intro?.contains(model.position) ?? false) }
    private var shouldOfferUpNext: Bool {
        model.ended || (model.markers.creditsStart.map { model.position >= $0 } ?? false)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let startAt { MPVHostView(model: model, item: item, startAt: startAt).ignoresSafeArea() }
            if !controlsVisible && !syncing && !inIntro && !upNextShown {
                Color.clear.focusable().onMoveCommand { _ in showControls() }
                    .onTapGesture { showControls() }
            }
            if syncing {
                SubSyncOverlay(model: model) { syncing = false; showControls() }
            } else if controlsVisible {
                ControlsOverlay(model: model, item: item,
                                hasPrev: prevEpisode != nil, hasNext: nextEpisode != nil,
                                onPrev: { go(prevEpisode) }, onNext: { go(nextEpisode) },
                                onAudio: { sheet = .audio }, onSubs: { sheet = .subtitles }, onSync: { startSync() },
                                onMore: { sheet = .more }, onInput: showControls)
            }
            if inIntro && !syncing {
                Button { model.skipIntro() } label: { Label("Skip Intro", systemImage: "forward.frame") }
                    .focused($skipFocused)
                    .defaultFocus($skipFocused, true)
                    .focusSection()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(60)
                    .onAppear { DispatchQueue.main.async { skipFocused = true } }
                    .onMoveCommand { _ in if !controlsVisible { showControls() } }   // swipe still reveals controls; overlay takes focus onAppear
            }
            if upNextShown && !syncing, let next = nextEpisode {
                UpNextBanner(next: next, countdown: upNextCountdown, onPlay: playUpNext, onCancel: cancelUpNext)
            }
            if let err = model.playbackError {
                VStack(spacing: 24) {
                    Text(err)
                    Button("Close") { close() }
                }.padding(60).background(.black.opacity(0.85))
            }
        }
        .confirmationDialog("Resume playback?", isPresented: $askResume, titleVisibility: .visible) {
            Button("Resume from \(clock(item.resumeFrom ?? 0))") { startAt = .some(item.resumeFrom) }
            Button("Start over") { startAt = .some(nil) }
        }
        .onPlayPauseCommand { model.togglePause(); showControls() }
        .onExitCommand { if syncing { return }; controlsVisible ? hide() : close() }
        .sheet(item: $sheet) { s in
            switch s {
            case .audio: TrackPicker(kind: .audio, model: model, item: item)
            case .subtitles: TrackPicker(kind: .subtitles, model: model, item: item, onSync: { startSync() })
            case .more: MoreSheet(model: model)
            }
        }
        .onChange(of: model.ended) { _, ended in
            guard ended else { return }
            if nextEpisode == nil || upNextDismissed { close() }
            else if !upNextShown { beginUpNext() }
        }
        .onChange(of: shouldOfferUpNext) { _, offer in
            if offer && nextEpisode != nil && !upNextDismissed && !upNextShown { beginUpNext() }
            else if !offer && !model.ended { clearUpNext() }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            showControls()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            hideTask?.cancel()
            if sheet == nil { shutdownOnce() }   // a sheet presented from here must not kill mpv
        }
    }

    private func startSync() { sheet = nil; hideTask?.cancel(); controlsVisible = false; syncing = true }

    private func hide() { hideTask?.cancel(); controlsVisible = false }

    private func showControls() {
        guard !upNextShown else { return }
        controlsVisible = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled && sheet == nil { controlsVisible = false }
        }
    }

    private func beginUpNext() {
        upNextShown = true
        hideTask?.cancel()
        controlsVisible = false
        guard autoplayNext else { return }
        upNextTask = Task {
            for n in stride(from: 10, to: 0, by: -1) {
                upNextCountdown = n
                try? await Task.sleep(for: .seconds(1))
                while model.paused {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                }
                if Task.isCancelled { return }
            }
            playUpNext()
        }
    }

    private func clearUpNext() { upNextTask?.cancel(); upNextTask = nil; upNextShown = false; upNextCountdown = nil }

    private func playUpNext() { let next = nextEpisode; clearUpNext(); go(next) }

    private func cancelUpNext() {
        clearUpNext()
        upNextDismissed = true
        if model.ended { close() }
    }

    private func go(_ episode: LibraryItem?) {
        guard let episode else { return }
        clearUpNext()
        upNextDismissed = false
        goTask?.cancel()
        goTask = Task {
            guard !closed else { return }
            guard let next = try? await PlayItemBuilder.make(for: episode, store: store) else {
                if model.ended { close() }
                return
            }
            guard !closed else { return }
            item = next
            model.advance(to: next)   // reloads on the same controller
            showControls()
        }
    }

    private func shutdownOnce() {
        guard !closed else { return }
        closed = true
        upNextTask?.cancel(); goTask?.cancel()
        model.shutdown()
    }

    private func close() { shutdownOnce(); dismiss() }
}
