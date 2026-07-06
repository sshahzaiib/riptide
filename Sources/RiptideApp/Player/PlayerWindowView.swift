import SwiftUI
import StreamCore

struct PlayerWindowView: View {
    let item: PlayItem
    let store: LibraryStore

    @State private var model: PlayerModel
    @State private var volume: Double = 100
    @State private var scrubbing = false
    @State private var scrubPosition: Double = 0
    @State private var controlsVisible = true
    @State private var showSubtitleSearch = false
    // Double-optional: nil = resume decision pending, .some(start) = decided.
    // Spec: an unfinished WatchState gets a Resume / Start Over prompt.
    @State private var resolvedStart: Double??
    @State private var showResumePrompt = false

    init(item: PlayItem, store: LibraryStore) {
        self.item = item
        self.store = store
        _model = State(initialValue: PlayerModel(store: store, itemKey: item.itemKey))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if let start = resolvedStart {
                MPVPlayerView(model: model, url: item.url, startAt: start)
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }

            if model.buffering {
                ProgressView().controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let error = model.playbackError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .padding(10)
                    .background(.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if controlsVisible {
                controls
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding(16)
                    .transition(.opacity)
            }
        }
        .onAppear {
            if let resume = item.resumeFrom, resume > 60 {
                showResumePrompt = true
            } else {
                resolvedStart = .some(nil)      // start from the beginning
            }
        }
        .alert("Resume playback?", isPresented: $showResumePrompt) {
            Button("Resume") { resolvedStart = .some(item.resumeFrom) }
            Button("Start Over") { resolvedStart = .some(nil) }
        } message: {
            Text("You stopped at \(format(item.resumeFrom ?? 0)).")
        }
        .onChange(of: showResumePrompt) {
            // Alert dismissed without a choice (Esc / click-away): default to
            // resuming rather than leaving the window black forever.
            if !showResumePrompt && resolvedStart == nil {
                resolvedStart = .some(item.resumeFrom)
            }
        }
        .onHover { hovering in
            controlsVisible = hovering || model.paused
        }
        .onContinuousHover { phase in
            if case .active = phase { controlsVisible = true }
        }
        .navigationTitle(item.title)
        .onDisappear { model.shutdown() }
        .sheet(isPresented: $showSubtitleSearch) {
            SubtitleSearchSheet(query: item.subtitleQuery,
                                season: item.season, episode: item.episode) { path in
                model.addSubtitle(path: path)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            // Seek bar with buffered range behind it.
            ZStack {
                GeometryReader { geo in
                    let buffered = model.duration > 0
                        ? min(model.cacheTime / model.duration, 1) : 0
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.white.opacity(0.25))
                        .frame(width: geo.size.width * buffered, height: 4)
                        .frame(maxHeight: .infinity, alignment: .center)
                }
                Slider(
                    value: Binding(
                        get: { scrubbing ? scrubPosition : model.position },
                        set: { scrubPosition = $0 }
                    ),
                    in: 0...max(model.duration, 1),
                    onEditingChanged: { editing in
                        scrubbing = editing
                        if !editing { model.seek(to: scrubPosition) }
                    }
                )
            }
            .frame(height: 20)

            HStack(spacing: 16) {
                Button(action: { model.togglePause() }) {
                    Image(systemName: model.paused ? "play.fill" : "pause.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])

                Text("\(format(model.position)) / \(format(model.duration))")
                    .font(.callout.monospacedDigit())

                Spacer()

                Menu {
                    ForEach(model.audioTracks) { track in
                        Button(action: { model.setAudioTrack(track.id) }) {
                            if track.selected { Image(systemName: "checkmark") }
                            Text(track.label)
                        }
                    }
                } label: { Image(systemName: "waveform") }
                .menuStyle(.borderlessButton)
                .frame(width: 44)
                .disabled(model.audioTracks.count < 2)

                Menu {
                    Button("Off") { model.setSubtitleTrack(nil) }
                    ForEach(model.subTracks) { track in
                        Button(action: { model.setSubtitleTrack(track.id) }) {
                            if track.selected { Image(systemName: "checkmark") }
                            Text(track.label)
                        }
                    }
                    Divider()
                    Button("Search OpenSubtitles…") { showSubtitleSearch = true }
                } label: { Image(systemName: "captions.bubble") }
                .menuStyle(.borderlessButton)
                .frame(width: 44)

                HStack(spacing: 4) {
                    Image(systemName: "speaker.wave.2")
                    Slider(value: $volume, in: 0...100)
                        .frame(width: 90)
                        .onChange(of: volume) { model.setVolume(volume) }
                }

                Button(action: {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                }) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let s = Int(seconds)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}
