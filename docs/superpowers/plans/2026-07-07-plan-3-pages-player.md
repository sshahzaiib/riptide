# Riptide Plan 3: Infuse-Style Pages + Full Player — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Infuse-style show/movie pages (backdrop hero, resume pill, episode strips with stills, cast rows) and a full player experience (resize/fullscreen fixes, keyboard shortcuts, auto-hide, speed, mute, skip intro).

**Architecture:** TMDB enrichment is fetched lazily by page view-models (no SwiftData schema change; URLCache handles revisits; offline degrades to filename UI). Player fixes replace the layer-hosting resize path with a custom NSView. Spec: `docs/superpowers/specs/2026-07-07-riptide-plan3-design.md`.

**Tech Stack:** Existing (SwiftUI, MPVKit/Libmpv, StreamCore).

## Global Constraints

- StreamCore stays Swift 6 strict, zero UI imports; RiptideApp stays `.swiftLanguageMode(.v5)`.
- All TMDB page fetches are best-effort: a failure hides that element, never blocks playback.
- Tests run `swift test` serial. App target verified by `swift build` (zero warnings) per task.
- No new dependencies. Commit per task, no co-author trailer.

---

### Task 1: TMDB Detail/Season/Credits Endpoints (StreamCore, TDD)

**Files:**
- Modify: `Sources/StreamCore/TMDB/TMDBModels.swift` (append)
- Modify: `Sources/StreamCore/TMDB/TMDBClient.swift` (append)
- Test: `Tests/StreamCoreTests/TMDBDetailTests.swift` (create)

**Interfaces:**
- Consumes: existing `TMDBClient.get(_:query:)` / `decode`.
- Produces (used by Tasks 4-5):
  - `func showDetails(id: Int) async throws -> TMDBShowDetails` — `{ id, name, backdropPath, overview, voteAverage, firstAirDate }`
  - `func seasonEpisodes(showID: Int, season: Int) async throws -> [TMDBSeasonEpisode]` — `{ episodeNumber, name, overview, stillPath, airDate, runtime? }`
  - `func showCredits(id: Int) async throws -> [TMDBCastMember]` / `func movieCredits(id: Int) async throws -> [TMDBCastMember]` — `{ id, name, character, profilePath }`, first 12
  - `func movieDetails(id: Int) async throws -> TMDBMovieDetails` — `{ id, title, backdropPath, overview, voteAverage, releaseDate, runtime? }`

- [ ] **Step 1: Write failing tests**

`Tests/StreamCoreTests/TMDBDetailTests.swift`:

```swift
import XCTest
@testable import StreamCore

final class TMDBDetailTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.setHandler(nil)
        super.tearDown()
    }

    private func client() -> TMDBClient {
        TMDBClient(bearerToken: "TOK", session: .mocked())
    }

    func testShowDetails() async throws {
        nonisolated(unsafe) var seen: URL?
        MockURLProtocol.setHandler { request in
            seen = request.url
            return .json("""
            {"id":1399,"name":"Game of Thrones","backdrop_path":"/b.jpg",
             "overview":"Seven noble families...","vote_average":8.4,
             "first_air_date":"2011-04-17"}
            """)
        }
        let details = try await client().showDetails(id: 1399)
        XCTAssertEqual(details.backdropPath, "/b.jpg")
        XCTAssertEqual(details.name, "Game of Thrones")
        XCTAssertTrue(try XCTUnwrap(seen).path.hasSuffix("/tv/1399"))
    }

    func testSeasonEpisodes() async throws {
        nonisolated(unsafe) var seen: URL?
        MockURLProtocol.setHandler { request in
            seen = request.url
            return .json("""
            {"id":3624,"episodes":[
              {"episode_number":1,"name":"Winter Is Coming","overview":"...",
               "still_path":"/s1.jpg","air_date":"2011-04-17","runtime":62},
              {"episode_number":2,"name":"The Kingsroad","overview":"...",
               "still_path":null,"air_date":"2011-04-24","runtime":null}]}
            """)
        }
        let episodes = try await client().seasonEpisodes(showID: 1399, season: 1)
        XCTAssertEqual(episodes.count, 2)
        XCTAssertEqual(episodes[0].name, "Winter Is Coming")
        XCTAssertEqual(episodes[0].runtime, 62)
        XCTAssertNil(episodes[1].stillPath)
        XCTAssertTrue(try XCTUnwrap(seen).path.hasSuffix("/tv/1399/season/1"))
    }

    func testCreditsCapAtTwelveAndRoute() async throws {
        nonisolated(unsafe) var paths: [String] = []
        let castJSON = (1...20).map {
            #"{"id":\#($0),"name":"Actor \#($0)","character":"Role \#($0)","profile_path":"/p\#($0).jpg"}"#
        }.joined(separator: ",")
        MockURLProtocol.setHandler { request in
            paths.append(request.url!.path)
            return .json(#"{"cast":[\#(castJSON)]}"#)
        }
        let show = try await client().showCredits(id: 1399)
        let movie = try await client().movieCredits(id: 603)
        XCTAssertEqual(show.count, 12)
        XCTAssertEqual(show.first?.name, "Actor 1")
        XCTAssertEqual(movie.count, 12)
        XCTAssertTrue(paths[0].hasSuffix("/tv/1399/credits"))
        XCTAssertTrue(paths[1].hasSuffix("/movie/603/credits"))
    }

    func testMovieDetails() async throws {
        MockURLProtocol.setHandler { _ in
            .json("""
            {"id":603,"title":"The Matrix","backdrop_path":"/mb.jpg",
             "overview":"A hacker...","vote_average":8.2,
             "release_date":"1999-03-30","runtime":136}
            """)
        }
        let details = try await client().movieDetails(id: 603)
        XCTAssertEqual(details.backdropPath, "/mb.jpg")
        XCTAssertEqual(details.runtime, 136)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter TMDBDetailTests` — compile error (types don't exist).

- [ ] **Step 3: Append models**

Append to `Sources/StreamCore/TMDB/TMDBModels.swift`:

```swift
public struct TMDBShowDetails: Sendable, Equatable, Decodable {
    public let id: Int
    public let name: String
    public let backdropPath: String?
    public let overview: String
    public let voteAverage: Double
    public let firstAirDate: String?

    enum CodingKeys: String, CodingKey {
        case id, name, overview
        case backdropPath = "backdrop_path"
        case voteAverage = "vote_average"
        case firstAirDate = "first_air_date"
    }
}

public struct TMDBSeasonEpisode: Sendable, Equatable, Decodable {
    public let episodeNumber: Int
    public let name: String
    public let overview: String
    public let stillPath: String?
    public let airDate: String?
    public let runtime: Int?

    enum CodingKeys: String, CodingKey {
        case name, overview, runtime
        case episodeNumber = "episode_number"
        case stillPath = "still_path"
        case airDate = "air_date"
    }
}

public struct TMDBCastMember: Sendable, Equatable, Decodable {
    public let id: Int
    public let name: String
    public let character: String?
    public let profilePath: String?

    enum CodingKeys: String, CodingKey {
        case id, name, character
        case profilePath = "profile_path"
    }
}

public struct TMDBMovieDetails: Sendable, Equatable, Decodable {
    public let id: Int
    public let title: String
    public let backdropPath: String?
    public let overview: String
    public let voteAverage: Double
    public let releaseDate: String?
    public let runtime: Int?

    enum CodingKeys: String, CodingKey {
        case id, title, overview, runtime
        case backdropPath = "backdrop_path"
        case voteAverage = "vote_average"
        case releaseDate = "release_date"
    }
}

struct TMDBSeasonEnvelope: Decodable {
    let episodes: [TMDBSeasonEpisode]
}

struct TMDBCreditsEnvelope: Decodable {
    let cast: [TMDBCastMember]
}
```

- [ ] **Step 4: Append client methods**

Append inside `TMDBClient` in `Sources/StreamCore/TMDB/TMDBClient.swift`:

```swift
    public func showDetails(id: Int) async throws -> TMDBShowDetails {
        try decode(TMDBShowDetails.self, from: try await get("tv/\(id)", query: [:]))
    }

    public func seasonEpisodes(showID: Int, season: Int) async throws -> [TMDBSeasonEpisode] {
        let data = try await get("tv/\(showID)/season/\(season)", query: [:])
        return try decode(TMDBSeasonEnvelope.self, from: data).episodes
    }

    public func showCredits(id: Int) async throws -> [TMDBCastMember] {
        let data = try await get("tv/\(id)/credits", query: [:])
        return Array(try decode(TMDBCreditsEnvelope.self, from: data).cast.prefix(12))
    }

    public func movieCredits(id: Int) async throws -> [TMDBCastMember] {
        let data = try await get("movie/\(id)/credits", query: [:])
        return Array(try decode(TMDBCreditsEnvelope.self, from: data).cast.prefix(12))
    }

    public func movieDetails(id: Int) async throws -> TMDBMovieDetails {
        try decode(TMDBMovieDetails.self, from: try await get("movie/\(id)", query: [:]))
    }
```

- [ ] **Step 5: Verify green + commit**

Run: `swift test` — expected 33 tests, 0 failures.

```bash
git add Sources/StreamCore/TMDB Tests/StreamCoreTests/TMDBDetailTests.swift
git commit -m "feat: TMDB detail/season/credits endpoints"
```

---

### Task 2: Player Core — Resize Fix + New Capabilities

**Files:**
- Modify: `Sources/RiptideApp/Player/MPVPlayerController.swift`
- Modify: `Sources/RiptideApp/Player/PlayerModel.swift`

**Interfaces:**
- Produces (used by Task 3): controller `setSpeed(_ speed: Double)`, `setMuted(_ muted: Bool)`, `toggleFullscreen()`, `skipIntro()`, `seek(relative: Double)`; PlayerModel mirrors all five plus published `muted: Bool`, `speed: Double`.

- [ ] **Step 1: Fix resize — custom video view**

In `Sources/RiptideApp/Player/MPVPlayerController.swift`, add this class ABOVE `final class MPVPlayerController`:

```swift
/// Layer-hosting video view. SwiftUI does not reliably drive
/// NSViewController.viewDidLayout for layer-hosting views, so the view itself
/// keeps the metal layer glued to its bounds and backing scale.
final class MPVVideoView: NSView {
    let metalLayer = MetalLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        metalLayer.frame = bounds
        metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = NSColor.black.cgColor
        layer = metalLayer
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func layout() {
        super.layout()
        syncLayer()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncLayer()
    }

    private func syncLayer() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        metalLayer.frame = bounds
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale,
                                         height: bounds.height * scale)
    }
}
```

Then in `MPVPlayerController`:
- Replace `var metalLayer = MetalLayer()` with `private let videoView = MPVVideoView(frame: .init(x: 0, y: 0, width: 1280, height: 720))` and add `var metalLayer: MetalLayer { videoView.metalLayer }`.
- Replace the whole `loadView()` with:

```swift
    override func loadView() {
        view = videoView
    }
```

- In `viewDidLoad()`, delete the six `metalLayer.*` / `view.layer` / `view.wantsLayer` setup lines (the view owns them now), keeping only `super.viewDidLoad()` and `setupMpv()`.
- Delete the entire `viewDidLayout()` override.
- In `setupMpv()`, the `wid` block stays exactly as is (it reads `metalLayer`, which now forwards to the view's layer). IMPORTANT: `Unmanaged.passUnretained(metalLayer)` still works because the computed property returns the same layer instance each time.

- [ ] **Step 2: Add capabilities to the controller**

Add after `setVolume`:

```swift
    func setSpeed(_ speed: Double) {
        var s = speed
        mpv_set_property(mpv, "speed", MPV_FORMAT_DOUBLE, &s)
    }

    func setMuted(_ muted: Bool) {
        setFlag("mute", muted)
    }

    func toggleFullscreen() {
        view.window?.toggleFullScreen(nil)
    }

    func seek(relative seconds: Double) {
        command("seek", args: [String(seconds), "relative"])
    }

    /// Next chapter if the file has one ahead; otherwise +90s.
    func skipIntro() {
        let chapterCount = getInt("chapter-list/count")
        let current = getInt("chapter")
        if chapterCount > 0, current + 1 < chapterCount {
            var next = Int64(current + 1)
            mpv_set_property(mpv, "chapter", MPV_FORMAT_INT64, &next)
        } else {
            seek(relative: 90)
        }
    }
```

- [ ] **Step 3: Extend PlayerModel**

In `Sources/RiptideApp/Player/PlayerModel.swift`, add published state after `playbackError`:

```swift
    private(set) var muted = false
    private(set) var speed: Double = 1.0
```

and add user intents after `addSubtitle`:

```swift
    func seek(relative seconds: Double) { controller?.seek(relative: seconds) }
    func toggleMute() {
        muted.toggle()
        controller?.setMuted(muted)
    }
    func setSpeed(_ newSpeed: Double) {
        speed = newSpeed
        controller?.setSpeed(newSpeed)
    }
    func toggleFullscreen() { controller?.toggleFullscreen() }
    func skipIntro() { controller?.skipIntro() }
```

- [ ] **Step 4: Build + commit**

Run: `swift build` — zero warnings. `swift test` — 33 green.

```bash
git add Sources/RiptideApp/Player
git commit -m "fix: video layer tracks window size; add speed/mute/fullscreen/skip-intro to player core"
```

---

### Task 3: Player Window — Shortcuts, Auto-Hide, New Controls

**Files:**
- Modify: `Sources/RiptideApp/Player/PlayerWindowView.swift` (REPLACE entire file)

**Interfaces:**
- Consumes: Task 2's PlayerModel API; existing PlayItem/SubtitleSearchSheet/MPVPlayerView.

- [ ] **Step 1: Replace PlayerWindowView.swift entirely with:**

```swift
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
    @State private var lastActivity = Date()
    @State private var showSubtitleSearch = false
    // Double-optional: nil = resume decision pending, .some(start) = decided.
    @State private var resolvedStart: Double??
    @State private var showResumePrompt = false
    @FocusState private var focused: Bool

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(item: PlayItem, store: LibraryStore) {
        self.item = item
        self.store = store
        _model = State(initialValue: PlayerModel(store: store, itemKey: item.itemKey))
    }

    private var showSkipIntro: Bool {
        item.season != nil && model.position > 0 && model.position < 360
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if let start = resolvedStart {
                MPVPlayerView(model: model, url: item.url, startAt: start)
                    .ignoresSafeArea()
                    .onTapGesture(count: 2) { model.toggleFullscreen() }
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
                        Button(action: { model.skipIntro() }) {
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
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.space) { model.togglePause(); return .handled }
        .onKeyPress(.leftArrow) { model.seek(relative: -10); return .handled }
        .onKeyPress(.rightArrow) { model.seek(relative: 10); return .handled }
        .onKeyPress(.upArrow) { bumpVolume(5); return .handled }
        .onKeyPress(.downArrow) { bumpVolume(-5); return .handled }
        .onKeyPress(KeyEquivalent("f")) { model.toggleFullscreen(); return .handled }
        .onKeyPress(KeyEquivalent("m")) { model.toggleMute(); return .handled }
        .onKeyPress(KeyEquivalent("s")) {
            if showSkipIntro { model.skipIntro() }
            return .handled
        }
        .onAppear {
            focused = true
            if let resume = item.resumeFrom, item.autoResume {
                resolvedStart = .some(resume)
            } else if let resume = item.resumeFrom, resume > 60 {
                showResumePrompt = true
            } else {
                resolvedStart = .some(nil)
            }
        }
        .alert("Resume playback?", isPresented: $showResumePrompt) {
            Button("Resume") { resolvedStart = .some(item.resumeFrom) }
            Button("Start Over") { resolvedStart = .some(nil) }
        } message: {
            Text("You stopped at \(format(item.resumeFrom ?? 0)).")
        }
        .onChange(of: showResumePrompt) {
            if !showResumePrompt && resolvedStart == nil {
                resolvedStart = .some(item.resumeFrom)
            }
        }
        .onContinuousHover { phase in
            if case .active = phase {
                lastActivity = Date()
                controlsVisible = true
            }
        }
        .onReceive(tick) { _ in
            if !model.paused && controlsVisible
                && Date().timeIntervalSince(lastActivity) > 3 && !scrubbing {
                controlsVisible = false
                NSCursor.setHiddenUntilMouseMoves(true)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
        .navigationTitle(item.title)
        .onDisappear { model.shutdown() }
        .sheet(isPresented: $showSubtitleSearch) {
            SubtitleSearchSheet(query: item.subtitleQuery,
                                season: item.season, episode: item.episode) { path in
                model.addSubtitle(path: path)
            }
        }
    }

    private func bumpVolume(_ delta: Double) {
        volume = min(max(volume + delta, 0), 100)
        model.setVolume(volume)
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
```

- [ ] **Step 2: Add `autoResume` to PlayItem**

In `Sources/RiptideApp/Player/PlayItem.swift`, add the field after `episode`:

```swift
    let autoResume: Bool           // explicit resume intent: skip the prompt
```

In `Sources/RiptideApp/Library/LibraryModel.swift`, change `playItem(for:)`'s signature to `func playItem(for item: LibraryItem, autoResume: Bool = false) async throws -> PlayItem` and pass `autoResume: autoResume` in the returned PlayItem.

In `Sources/RiptideApp/Library/LibraryViews.swift`, `PlayableCard.play()` (Continue Watching): call `model.playItem(for: item, autoResume: true)`.

- [ ] **Step 3: Build + commit**

Run: `swift build` — zero warnings; `swift test` — 33 green.

```bash
git add Sources/RiptideApp
git commit -m "feat: full player experience — shortcuts, auto-hide, speed, mute, skip intro"
```

---

### Task 4: Show Page (hero + season strips + cast)

**Files:**
- Create: `Sources/RiptideApp/Library/ShowPageModel.swift`
- Create: `Sources/RiptideApp/Library/CastRow.swift`
- Modify: `Sources/RiptideApp/Library/ItemDetailView.swift` — REPLACE the `ShowDetailView` struct (keep `ItemDetailView` untouched this task)

**Interfaces:**
- Consumes: Task 1 endpoints, `LibraryModel.playItem(for:autoResume:)`, ShowGroup.
- Produces: `ShowPageModel` (`load()`, `episodeMeta(for:)`, `resumeTarget`, `details`, `cast`), `CastRow(cast: [TMDBCastMember])` (reused Task 5).

- [ ] **Step 1: Write ShowPageModel**

`Sources/RiptideApp/Library/ShowPageModel.swift`:

```swift
import Foundation
import Observation
import StreamCore

/// Lazy TMDB enrichment for one show page. Every fetch is best-effort:
/// failures leave the corresponding field nil/empty and the UI falls back
/// to filename-based rendering.
@Observable
@MainActor
final class ShowPageModel {
    let show: ShowGroup
    private let store: LibraryStore

    private(set) var details: TMDBShowDetails?
    private(set) var cast: [TMDBCastMember] = []
    // season -> episodeNumber -> metadata
    private(set) var seasonMeta: [Int: [Int: TMDBSeasonEpisode]] = [:]
    var selected: LibraryItem?

    init(show: ShowGroup, store: LibraryStore) {
        self.show = show
        self.store = store
        self.selected = resumeTarget?.item ?? show.episodes.first
    }

    var showID: Int? { show.episodes.compactMap(\.tmdbID).first }

    var seasons: [(number: Int, episodes: [LibraryItem])] {
        Dictionary(grouping: show.episodes) { $0.season ?? 0 }
            .map { (number: $0.key, episodes: $0.value) }
            .sorted { $0.number < $1.number }
    }

    /// Most recently watched, unfinished episode of this show.
    var resumeTarget: (item: LibraryItem, position: Double)? {
        let keys = Dictionary(uniqueKeysWithValues: show.episodes.map { ($0.itemKey, $0) })
        guard let state = (try? store.continueWatching())?
            .first(where: { keys[$0.itemKey] != nil }),
              let item = keys[state.itemKey] else { return nil }
        return (item, state.positionSeconds)
    }

    func watchState(for item: LibraryItem) -> (progress: Double, finished: Bool)? {
        // continueWatching() excludes finished; fetch all states via progress query.
        guard let states = try? store.allWatchStates() else { return nil }
        guard let state = states.first(where: { $0.itemKey == item.itemKey }),
              state.durationSeconds > 0 else { return nil }
        return (state.positionSeconds / state.durationSeconds, state.finished)
    }

    func episodeMeta(for item: LibraryItem) -> TMDBSeasonEpisode? {
        guard let season = item.season, let episode = item.episode else { return nil }
        return seasonMeta[season]?[episode]
    }

    func load(tmdb: TMDBClient) async {
        guard let showID else { return }
        if let fetched = try? await tmdb.showDetails(id: showID) { details = fetched }
        if let fetched = try? await tmdb.showCredits(id: showID) { cast = fetched }
        for season in seasons where season.number > 0 {
            guard seasonMeta[season.number] == nil,
                  let episodes = try? await tmdb.seasonEpisodes(showID: showID,
                                                                season: season.number)
            else { continue }
            seasonMeta[season.number] = Dictionary(
                uniqueKeysWithValues: episodes.map { ($0.episodeNumber, $0) })
        }
    }
}
```

Also add to `Sources/StreamCore/Store/LibraryStore.swift` (after `continueWatching`):

```swift
    /// Every stored watch state (finished included) — show pages badge
    /// finished episodes with it.
    public func allWatchStates() throws -> [WatchState] {
        try context.fetch(FetchDescriptor<WatchState>())
    }
```

- [ ] **Step 2: Write CastRow**

`Sources/RiptideApp/Library/CastRow.swift`:

```swift
import SwiftUI
import StreamCore

struct CastRow: View {
    let cast: [TMDBCastMember]

    var body: some View {
        if !cast.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Cast").font(.title3.bold())
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(cast, id: \.id) { member in
                            VStack(spacing: 6) {
                                AsyncImage(url: member.profilePath.map {
                                    TMDB.imageURL(path: $0, width: 185)
                                }) { image in
                                    image.resizable().aspectRatio(contentMode: .fill)
                                } placeholder: {
                                    ZStack {
                                        Circle().fill(.quaternary)
                                        Image(systemName: "person.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .frame(width: 72, height: 72)
                                .clipShape(Circle())

                                Text(member.name)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                if let character = member.character {
                                    Text(character)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .frame(width: 90)
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
    }
}
```

- [ ] **Step 3: Replace ShowDetailView**

In `Sources/RiptideApp/Library/ItemDetailView.swift`, REPLACE the whole `ShowDetailView` struct with:

```swift
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
```

Note: `LibraryModel` must expose its store — in `Sources/RiptideApp/Library/LibraryModel.swift` the property is already `let store: LibraryStore` (non-private). Verify; if private, make it non-private.

- [ ] **Step 4: Build + commit**

Run: `swift build` (zero warnings), `swift test` (33 green — the `allWatchStates` addition compiles with StreamCore).

```bash
git add Sources/RiptideApp/Library Sources/StreamCore/Store/LibraryStore.swift
git commit -m "feat: Infuse-style show page — backdrop hero, resume pill, episode strips, cast"
```

---

### Task 5: Movie Page Hero + Manual E2E

**Files:**
- Modify: `Sources/RiptideApp/Library/ItemDetailView.swift` — REPLACE the `ItemDetailView` struct

**Interfaces:**
- Consumes: `movieDetails`/`movieCredits` (Task 1), `CastRow` (Task 4), `playItem(for:autoResume:)`.

- [ ] **Step 1: Replace ItemDetailView**

REPLACE the whole `ItemDetailView` struct in `Sources/RiptideApp/Library/ItemDetailView.swift` with:

```swift
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
```

- [ ] **Step 2: Build + commit**

Run: `swift build` (zero warnings), `swift test` (33 green).

```bash
git add Sources/RiptideApp/Library
git commit -m "feat: movie page hero with backdrop, resume pill, cast row"
```

- [ ] **Step 3: Manual E2E (human)**

`swift run RiptideApp`: resize player mid-play (video must fill), F/green-button fullscreen, all shortcuts, skip intro on GoT E1, show page (backdrop + 5 season strips with stills + cast), resume pill timestamp, movie hero, double-click fullscreen, auto-hide after 3s.

---

## Exit Criteria

`swift build` zero warnings; `swift test` 33 green; manual checklist passes; commits pushed to PR #1 branch.
