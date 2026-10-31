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
    @State private var showSubtitleStyle = false
    // Double-optional: nil = resume decision pending, .some(start) = decided.
    @State private var resolvedStart: Double??
    @State private var showResumePrompt = false
    @State private var keyMonitor: Any?
    @State private var episodeName: String?

    @AppStorage("autoplayNext") private var autoplayNext = true
    @State private var upNextItem: LibraryItem?      // next episode, pre-unrestrict
    @State private var upNextPlay: PlayItem?         // unrestricted, ready to go
    @State private var upNextCountdown: Int?
    @State private var upNextFailed = false
    @State private var upNextDismissed = false       // user hit Cancel this playback
    @State private var upNextTask: Task<Void, Never>?
    // Adjacent owned episodes (same no-skip rules as Up Next) — drive the
    // prev/next controls; nil disables the button.
    @State private var prevEpisodeItem: LibraryItem?
    @State private var nextEpisodeItem: LibraryItem?
    // Stremio-style loading screen: set while a prev/next/up-next swap is
    // unrestricting + loading; also shown on initial open (duration == 0).
    @State private var switchingTo: LibraryItem?
    @State private var logoURL: URL?                 // TMDB title-treatment art
    @State private var logoFetchedFor: Int?
    @State private var loadingPulse = false
    // Controls pill drag: offset from its default bottom-center anchor.
    @State private var controlsOffset: CGSize = .zero
    @State private var controlsDragStart: CGSize?
    @State private var windowSize: CGSize = .zero

    init(item: PlayItem, store: LibraryStore) {
        self.item = item
        self.store = store
        _current = State(initialValue: item)
        _model = State(initialValue: PlayerModel(store: store, itemKey: item.itemKey,
                                                 traktMedia: TraktMedia(playItem: item)))
    }

    // Episodes only, and only while the detected intro is actually playing.
    // No `used` flag needed: pressing it seeks past the window, which closes it.
    private var showSkipIntro: Bool {
        guard current.season != nil, let intro = model.markers.intro else { return false }
        return intro.contains(model.position)
    }

    // Up Next used to wait for EOF, which meant sitting through the whole credits
    // and then a 10s countdown. Offer it when the credits chapter starts; files
    // with no credits chapter keep the EOF behavior.
    private var shouldOfferUpNext: Bool {
        if model.ended { return true }
        if let credits = model.markers.creditsStart { return model.position >= credits }
        return false
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

            if model.playbackError == nil, switchingTo != nil || model.duration == 0 {
                loadingOverlay
                    .transition(.opacity)
            }

            if controlsVisible {
                if model.isMiniPlayer {
                    miniControls
                        .transition(.opacity)
                } else {
                    VStack(spacing: 8) {
                        if showSkipIntro {
                            Button(action: { model.skipIntro() }) {
                                Label("Skip Intro", systemImage: "forward.frame")
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .clearGlass(in: .capsule)
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.trailing, 16)
                        }
                        controls
                            .padding(12)
                            // Floating pill, not a full-width bar: 45% of the
                            // window, clamped so sliders stay usable on small
                            // windows and it never exceeds the old edge insets.
                            .containerRelativeFrame(.horizontal) { length, _ in
                                min(max(length * 0.45, 560), max(length - 32, 320))
                            }
                            .clearGlass(in: .rect(cornerRadius: 16))
                            .padding(16)
                            .offset(controlsOffset)
                            // Drag the pill by any non-interactive spot (sliders
                            // and buttons keep gesture priority).
                            .gesture(
                                DragGesture()
                                    .onChanged { value in
                                        let start = controlsDragStart ?? controlsOffset
                                        controlsDragStart = start
                                        controlsOffset = clampedControlsOffset(
                                            CGSize(width: start.width + value.translation.width,
                                                   height: start.height + value.translation.height))
                                    }
                                    .onEnded { _ in controlsDragStart = nil }
                            )
                    }
                    .transition(.opacity)
                }
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
        .task(id: current.itemKey) {
            episodeName = nil
            prevEpisodeItem = (try? store.previousEpisode(before: current.itemKey)) ?? nil
            nextEpisodeItem = (try? store.nextEpisode(after: current.itemKey)) ?? nil
            guard let id = current.tmdbID else { logoURL = nil; return }
            let token = AppSettings.shared.tmdbToken
            guard !token.isEmpty else { return }
            let client = TMDBClient(bearerToken: token, cache: .shared)
            // Loading-screen art (best-effort, cached per title — prev/next
            // within a show reuse it instantly).
            if logoFetchedFor != id {
                let path = current.season == nil
                    ? try? await client.logoPath(movieID: id)
                    : try? await client.logoPath(showID: id)
                guard !Task.isCancelled else { return }
                logoURL = path.map { TMDB.imageURL(path: $0) }
                logoFetchedFor = id
            }
            guard let s = current.season, let e = current.episode else { return }
            // Best-effort: a TMDB miss just leaves the numeric label.
            let name = try? await client.episode(showID: id, season: s, episode: e).name
            // A cancelled fetch (advance mid-flight) must not clobber the
            // replacement task's result.
            guard !Task.isCancelled else { return }
            episodeName = name
        }
        .onChange(of: model.duration) {
            // The next file's metadata arrived — the swap is done.
            if model.duration > 0 { switchingTo = nil }
        }
        .onGeometryChange(for: CGSize.self, of: \.size) { size in
            windowSize = size
            // Mini mode: the pill is hidden and the window tiny — clamping
            // here would permanently wreck the user's dragged offset.
            if !model.isMiniPlayer {
                controlsOffset = clampedControlsOffset(controlsOffset)
            }
        }
        .overlay(alignment: .topLeading) {
            if controlsVisible && !model.isMiniPlayer {
                nowPlayingTitle
                    .padding(16)
                    .transition(.opacity)
            }
        }
        .onChange(of: controlsVisible, initial: true) {
            // Mini mode shows a tiny bar, not the pill — nothing to clear.
            model.setSubtitlesRaised(controlsVisible && !model.isMiniPlayer)
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
            SubtitleSearchSheet(query: current.subtitleQuery, itemKey: current.itemKey,
                                season: current.season, episode: current.episode) { path, key in
                // key = the sheet's value-captured itemKey, NOT current.itemKey:
                // @State reads here are dynamic, so an episode auto-advance
                // mid-download would make the staleness guard compare the new
                // key against itself and always pass.
                model.addSubtitle(path: path, expecting: key)
            }
            // Identity pinned to the item: an episode auto-advance while the
            // sheet is open would otherwise keep the OLD episode's @State
            // (results/cachedIDs) under the NEW itemKey — a tap would file the
            // old episode's subtitle under the new one. .id() resets the sheet
            // to a fresh search for the new item instead.
            .id(current.itemKey)
        }
        .onChange(of: shouldOfferUpNext) {
            if shouldOfferUpNext {
                beginUpNext()
            } else {
                // Seek back out of the credits (or back from the end frame):
                // retract the card and re-arm.
                upNextTask?.cancel()
                clearUpNext()
                upNextDismissed = false
            }
        }
    }

    /// Keep the dragged pill reachable: never past the window edges (the
    /// pill anchors bottom-center, so up is negative height).
    private func clampedControlsOffset(_ offset: CGSize) -> CGSize {
        guard windowSize.width > 0 else { return offset }
        let halfSpan = max(windowSize.width / 2 - 120, 0)
        return CGSize(width: min(max(offset.width, -halfSpan), halfSpan),
                      height: min(max(offset.height, -max(windowSize.height - 140, 0)), 0))
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
        case 53:                               // esc — exit mini, else dismiss Up Next
            if model.isMiniPlayer {
                model.toggleMiniPlayer()
                break
            }
            guard upNextItem != nil else { return false }
            upNextTask?.cancel()
            clearUpNext()
            upNextDismissed = true
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "f": model.toggleFullscreen()
            case "m": model.toggleMute()
            case "p": model.toggleMiniPlayer()
            case "s": if showSkipIntro { model.skipIntro() }
            case "g": model.adjustSubDelay(by: -PlayerModel.subDelayStep)
            case "h": model.adjustSubDelay(by: PlayerModel.subDelayStep)
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
        withAnimation(.easeInOut(duration: 0.25)) { upNextItem = next }
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
        switchingTo = upNextItem
        advanceWindow(to: next)
        clearUpNext()
    }

    /// Swap this window (and its per-episode view state) to another item.
    private func advanceWindow(to built: PlayItem) {
        episodeName = nil          // don't flash the old episode's name
        current = built
        resolvedStart = .some(built.resumeFrom)
        model.advance(to: built)
    }

    /// Prev/next controls: unrestrict the adjacent episode and swap to it.
    private func skip(to target: LibraryItem?) {
        guard let target else { return }
        upNextTask?.cancel()
        clearUpNext()
        switchingTo = target
        Task {
            // ponytail: unrestrict failure just leaves the current episode
            // playing — the button stays enabled, clicking again retries.
            guard let built = try? await PlayItemBuilder.make(
                for: target, store: store, autoResume: true)
            else { switchingTo = nil; return }
            advanceWindow(to: built)
        }
    }

    private func clearUpNext() {
        withAnimation(.easeInOut(duration: 0.25)) { upNextItem = nil }
        upNextPlay = nil
        upNextCountdown = nil
        upNextFailed = false
        upNextTask = nil
    }

    /// Stremio-style loading screen: the title's logo art (fallback: styled
    /// title text) pulsing on black while a stream unrestricts and loads.
    private var loadingOverlay: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 24) {
                Group {
                    if let logoURL {
                        AsyncImage(url: logoURL) { phase in
                            if case .success(let image) = phase {
                                image.resizable().scaledToFit()
                            } else {
                                loadingTitleText
                            }
                        }
                    } else {
                        loadingTitleText
                    }
                }
                .frame(maxWidth: 420, maxHeight: 150)
                .opacity(loadingPulse ? 1.0 : 0.35)

                if let target = switchingTo, let s = target.season, let e = target.episode {
                    Text("S\(s)E\(e)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            loadingPulse = false
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                loadingPulse = true
            }
        }
    }

    private var loadingTitleText: some View {
        Text(switchingTo?.title ?? current.subtitleQuery)
            .font(.system(size: 40, weight: .heavy, design: .rounded))
            .foregroundStyle(.white.opacity(0.9))
            .lineLimit(2)
            .multilineTextAlignment(.center)
    }

    /// Show/movie name (subtitleQuery is the parsed title — no SxEy suffix),
    /// plus an episode line when TMDB knows the name.
    private var nowPlayingTitle: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(current.subtitleQuery)
                .font(.headline)
                .lineLimit(1)
            if let s = current.season, let e = current.episode {
                Text("S\(s)E\(e)\(episodeName.map { " · \($0)" } ?? "")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .clearGlass(in: .rect(cornerRadius: 12))
        .allowsHitTesting(false)
    }

    /// Mini-player hover overlay: play/pause, restore, close — nothing else.
    /// Everything heavier (seek, tracks, volume) means restoring first.
    private var miniControls: some View {
        HStack(spacing: 14) {
            Button(action: { model.togglePause() }) {
                Image(systemName: model.paused ? "play" : "pause")
                    .font(.title3.weight(.medium))
            }
            .buttonStyle(.plain)

            Button(action: { model.toggleMiniPlayer() }) {
                Image(systemName: "pip.exit")
                    .font(.title3.weight(.medium))
            }
            .buttonStyle(.plain)
            .help("Exit mini player")

            Button(action: { model.hostWindow?.close() }) {
                Image(systemName: "xmark")
                    .font(.title3.weight(.medium))
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .clearGlass(in: .capsule)
        .padding(12)
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
                        .glassButton()
                    Text("Couldn't fetch the stream").font(.callout).foregroundStyle(.secondary)
                } else {
                    Button(action: { upNextTask?.cancel(); playUpNext() }) {
                        Label(upNextCountdown.map { "Playing in \($0)s" } ?? "Play Now",
                              systemImage: "play.fill")
                    }
                    .glassButton(prominent: true)
                    .disabled(upNextPlay == nil)
                }
                Button("Cancel") {
                    upNextTask?.cancel()
                    clearUpNext()
                    upNextDismissed = true
                }
                .glassButton()
            }
        }
        .padding(16)
        .clearGlass(in: .rect(cornerRadius: 16))
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

            HStack(spacing: 10) {
                if current.season != nil {
                    Button(action: { skip(to: prevEpisodeItem) }) {
                        Image(systemName: "backward.end")
                            .font(.body.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .disabled(prevEpisodeItem == nil)
                    .opacity(prevEpisodeItem == nil ? 0.35 : 1)
                    .help("Previous episode")
                }

                Button(action: { model.togglePause() }) {
                    Image(systemName: model.paused ? "play" : "pause")
                        .font(.title2.weight(.medium))
                }
                .buttonStyle(.plain)

                if current.season != nil {
                    Button(action: { skip(to: nextEpisodeItem) }) {
                        Image(systemName: "forward.end")
                            .font(.body.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .disabled(nextEpisodeItem == nil)
                    .opacity(nextEpisodeItem == nil ? 0.35 : 1)
                    .help("Next episode")
                }

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
                .frame(width: 32)

                Menu {
                    ForEach(model.audioTracks) { track in
                        Button(action: { model.setAudioTrack(track.id) }) {
                            if track.selected { Image(systemName: "checkmark") }
                            Text(track.label)
                        }
                    }
                } label: { Image(systemName: "waveform") }
                .menuStyle(.borderlessButton)
                .frame(width: 32)
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
                    Divider()
                    if model.subDelay != 0 {
                        Text("Delay: \(PlayerModel.formatMS(model.subDelay))")
                        Button("Reset Delay") { model.resetSubDelay() }
                    }
                    Button("Subtitle Style…") { showSubtitleStyle = true }
                } label: { Image(systemName: "captions.bubble") }
                .menuStyle(.borderlessButton)
                .frame(width: 32)
                .popover(isPresented: $showSubtitleStyle, arrowEdge: .top) {
                    Form {
                        SubtitleStyleControls { model.applySubtitleStyle($0) }
                    }
                    .formStyle(.grouped)
                    .frame(width: 280)
                    // ponytail: live-applies only to THIS window's mpv; other
                    // open players pick styling up on next file load. Upgrade
                    // path: NotificationCenter broadcast.
                }

                Button(action: { model.toggleMute() }) {
                    Image(systemName: model.muted ? "speaker.slash" : "speaker.wave.2")
                }
                .buttonStyle(.plain)

                Slider(value: $volume, in: 0...100)
                    .frame(width: 90)
                    .onChange(of: volume) { model.setVolume(volume) }

                Button(action: { model.toggleMiniPlayer() }) {
                    Image(systemName: "pip.enter")
                }
                .buttonStyle(.plain)
                .help("Mini player")

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

// Liquid Glass on macOS 26+, material/bordered look on older systems.
private extension View {
    @ViewBuilder func clearGlass<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.clear, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }

    @ViewBuilder func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }
}
