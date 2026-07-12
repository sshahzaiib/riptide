import SwiftUI
import StreamCore
import class StreamCore.LibraryItem

struct PlayerWindowView: View {
    let item: PlayItem
    let store: LibraryStore

    @State private var current: PlayItem
    @State private var model: PlayerModel
    @State private var volume: Double = 100
    @State private var scrubbing = false
    @State private var scrubPosition: Double = 0
    @State private var controlsVisible = true
    @State private var lastActivity = Date()
    @State private var showSubtitleSearch = false
    // Double-optional: nil = resume decision pending, .some(start) = decided.
    @State private var resolvedStart: Double??
    @State private var showResumePrompt = false
    @State private var keyMonitor: Any?
    @State private var skipIntroUsed = false

    @AppStorage("autoplayNext") private var autoplayNext = true
    @State private var upNextItem: LibraryItem?      // next episode, pre-unrestrict
    @State private var upNextPlay: PlayItem?         // unrestricted, ready to go
    @State private var upNextCountdown: Int?
    @State private var upNextFailed = false
    @State private var upNextDismissed = false       // user hit Cancel this playback
    @State private var upNextTask: Task<Void, Never>?

    init(item: PlayItem, store: LibraryStore) {
        self.item = item
        self.store = store
        _current = State(initialValue: item)
        _model = State(initialValue: PlayerModel(store: store, itemKey: item.itemKey,
                                                 traktMedia: TraktMedia(playItem: item)))
    }

    // Episodes only, once per playback, and only during the first 6 minutes.
    private var showSkipIntro: Bool {
        current.season != nil && !skipIntroUsed && model.position > 0 && model.position < 360
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if let start = resolvedStart {
                MPVPlayerView(model: model, url: current.url, startAt: start)
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
                VStack(alignment: .trailing, spacing: 8) {
                    if showSkipIntro {
                        Button(action: { model.skipIntro(); skipIntroUsed = true }) {
                            Label("Skip Intro", systemImage: "forward.frame")
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 16)
                    }
                    controls
                        .padding(12)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .padding(16)
                }
                .transition(.opacity)
            }

            if let next = upNextItem {
                upNextCard(next)
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onAppear {
            // SwiftUI onKeyPress never fires in this NSView-hosting window
            // (first responder stays on the video view), so shortcuts are an
            // AppKit local monitor scoped to this window.
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.window === model.hostWindow,
                      event.modifierFlags.intersection([.command, .option, .control]).isEmpty
                else { return event }
                return handleKey(event) ? nil : event
            }
            if let resume = current.resumeFrom, current.autoResume, resume > 60 {
                resolvedStart = .some(resume)
            } else if let resume = current.resumeFrom, resume > 60 {
                showResumePrompt = true
            } else {
                resolvedStart = .some(nil)
            }
        }
        .alert("Resume playback?", isPresented: $showResumePrompt) {
            Button("Resume") { resolvedStart = .some(current.resumeFrom) }
            Button("Start Over") { resolvedStart = .some(nil) }
        } message: {
            Text("You stopped at \(format(current.resumeFrom ?? 0)).")
        }
        .onChange(of: showResumePrompt) {
            if !showResumePrompt && resolvedStart == nil {
                resolvedStart = .some(current.resumeFrom)
            }
        }
        .onContinuousHover { phase in
            if case .active = phase {
                lastActivity = Date()
                controlsVisible = true
            }
        }
        .task {
            // Diagnostics: RIPTIDE_DEBUG_SUB=<path.srt> exercises sub-add +
            // deselect without UI interaction (like RIPTIDE_DEBUG_URL).
            if let sub = ProcessInfo.processInfo.environment["RIPTIDE_DEBUG_SUB"] {
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    model.addSubtitle(path: sub)
                    try? await Task.sleep(for: .seconds(3))
                    model.setSubtitleTrack(nil)
                }
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if !model.paused && controlsVisible
                    && Date().timeIntervalSince(lastActivity) > 3 && !scrubbing {
                    controlsVisible = false
                    NSCursor.setHiddenUntilMouseMoves(true)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
        .navigationTitle(current.title)
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            upNextTask?.cancel()
            model.shutdown()
        }
        .sheet(isPresented: $showSubtitleSearch) {
            SubtitleSearchSheet(query: current.subtitleQuery,
                                season: current.season, episode: current.episode) { path in
                model.addSubtitle(path: path)
            }
        }
        .onChange(of: model.ended) {
            if model.ended {
                beginUpNext()
            } else {
                // Seek back from the end frame: retract the card and re-arm.
                upNextTask?.cancel()
                clearUpNext()
                upNextDismissed = false
            }
        }
    }

    private func bumpVolume(_ delta: Double) {
        volume = min(max(volume + delta, 0), 100)
        model.setVolume(volume)
    }

    /// Returns true when the event was consumed as a shortcut.
    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 49:  model.togglePause()          // space
        case 123: model.seek(relative: -10)    // ←
        case 124: model.seek(relative: 10)     // →
        case 126: bumpVolume(5)                // ↑
        case 125: bumpVolume(-5)               // ↓
        case 53:                               // esc — dismiss Up Next card
            guard upNextItem != nil else { return false }
            upNextTask?.cancel()
            clearUpNext()
            upNextDismissed = true
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "f": model.toggleFullscreen()
            case "m": model.toggleMute()
            case "s": if showSkipIntro { model.skipIntro(); skipIntroUsed = true }
            default: return false
            }
        }
        lastActivity = Date()
        controlsVisible = true
        return true
    }

    private func beginUpNext() {
        guard !upNextDismissed, upNextItem == nil,
              let next = (try? store.nextEpisode(after: current.itemKey)) ?? nil
        else { return }
        upNextItem = next
        upNextFailed = false
        upNextTask = Task {
            let built: PlayItem
            do {
                built = try await PlayItemBuilder.make(for: next, store: store, autoResume: true)
            } catch {
                if !Task.isCancelled { upNextFailed = true }
                return
            }
            guard !Task.isCancelled else { return }
            upNextPlay = built
            guard autoplayNext else { return }
            for remaining in stride(from: 10, through: 0, by: -1) {
                upNextCountdown = remaining
                guard remaining > 0 else { break }
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
            }
            playUpNext()
        }
    }

    private func playUpNext() {
        guard let next = upNextPlay else { return }
        current = next
        resolvedStart = .some(next.resumeFrom)
        skipIntroUsed = false
        model.advance(to: next)
        clearUpNext()
    }

    private func clearUpNext() {
        upNextItem = nil
        upNextPlay = nil
        upNextCountdown = nil
        upNextFailed = false
        upNextTask = nil
    }

    private func upNextCard(_ next: LibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Up Next").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text("S\(next.season ?? 0)E\(next.episode ?? 0) · \(next.title)")
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 10) {
                if upNextFailed {
                    Button("Retry") { clearUpNext(); beginUpNext() }
                        .buttonStyle(.borderedProminent)
                    Text("Couldn't fetch the stream").font(.callout).foregroundStyle(.secondary)
                } else {
                    Button(action: { upNextTask?.cancel(); playUpNext() }) {
                        Label(upNextCountdown.map { "Playing in \($0)s" } ?? "Play Now",
                              systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(upNextPlay == nil)
                }
                Button("Cancel") {
                    upNextTask?.cancel()
                    clearUpNext()
                    upNextDismissed = true
                }
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .animation(.easeInOut(duration: 0.2), value: upNextCountdown)
    }

    private var controls: some View {
        VStack(spacing: 8) {
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

                Text("\(format(model.position)) / \(format(model.duration))")
                    .font(.callout.monospacedDigit())

                Spacer()

                Menu {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                        Button(action: { model.setSpeed(rate) }) {
                            if model.speed == rate { Image(systemName: "checkmark") }
                            Text(rate == 1.0 ? "Normal" : String(format: "%g×", rate))
                        }
                    }
                } label: { Image(systemName: "gauge.with.needle") }
                .menuStyle(.borderlessButton)
                .frame(width: 44)

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

                Button(action: { model.toggleMute() }) {
                    Image(systemName: model.muted ? "speaker.slash" : "speaker.wave.2")
                }
                .buttonStyle(.plain)

                Slider(value: $volume, in: 0...100)
                    .frame(width: 90)
                    .onChange(of: volume) { model.setVolume(volume) }

                Button(action: { model.toggleFullscreen() }) {
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
