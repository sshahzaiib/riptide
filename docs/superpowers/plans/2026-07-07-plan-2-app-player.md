# Riptide Plan 2: App + MPVKit Player Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the RiptideApp SwiftUI executable: MPVKit-embedded player, library shelves with TMDB posters, settings/Keychain, and the refresh pipeline — everything deferred from Plan 1.

**Architecture:** One new `executableTarget` (RiptideApp) depending on StreamCore + MPVKit. Pure orchestration (LibraryRefresher) goes into StreamCore where it is unit-testable; the app target holds UI and mpv C-interop, verified by building and a final manual E2E checklist. The mpv integration is adapted from MPVKit's own macOS demo (CAMetalLayer as `wid`, vo=gpu-next/vulkan/moltenvk, wakeup-callback event loop) — reference copies of the demo files are in `/private/tmp/claude-501/-Users-shahzaib-Documents-dev/ac8c0ee4-096c-4ca5-9f03-08673ec30fb9/scratchpad/mpvkit-demo/` (read-only; do not copy verbatim, the plan below contains the adapted code).

**Tech Stack:** Swift 6 toolchain, SwiftUI + @Observable (macOS 14), MPVKit 0.41.0 (LGPL product, `import Libmpv`), SwiftData (via StreamCore), Security.framework (Keychain).

## Global Constraints

- `Sources/StreamCore/` keeps **zero** `import SwiftUI` / `import AppKit`; StreamCore stays Swift 6 strict (no language-mode override).
- `RiptideApp` target compiles with `.swiftLanguageMode(.v5)` (mpv C callbacks are not strict-concurrency-clean; scoping the downgrade to the app target is deliberate).
- MPVKit is the ONLY third-party dependency; use product `MPVKit` (LGPL), NEVER `MPVKit-GPL`.
- Tests: `swift test` serial (MockURLProtocol constraint). App target has no unit tests — it is verified by `swift build` per task and the Task 7 manual checklist.
- Keychain service string: `"com.northlab.riptide"`; accounts: `"rd-token"`, `"tmdb-token"`, `"opensubtitles-key"`.
- WatchState itemKey format (from Plan 1): `"<torrentID>#<fileIndex>"`.
- Commit after each task. No Claude co-author trailer.
- First build after adding MPVKit downloads large binary xcframeworks (one-time, several hundred MB) — `swift build` may take several minutes; do not kill it.

---

### Task 1: App Target Scaffold + MPVKit Dependency

**Files:**
- Modify: `Package.swift`
- Create: `Sources/RiptideApp/RiptideApp.swift`

**Interfaces:**
- Consumes: StreamCore library (Plan 1).
- Produces: `RiptideApp` executable target that later tasks add files into; `@main struct Riptide: App` entry point.

- [ ] **Step 1: Replace Package.swift**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Riptide",
    platforms: [.macOS(.v14)],
    products: [.library(name: "StreamCore", targets: ["StreamCore"])],
    dependencies: [
        .package(url: "https://github.com/mpvkit/MPVKit.git", from: "0.41.0"),
    ],
    targets: [
        .target(name: "StreamCore"),
        .testTarget(name: "StreamCoreTests", dependencies: ["StreamCore"]),
        .executableTarget(
            name: "RiptideApp",
            dependencies: [
                "StreamCore",
                .product(name: "MPVKit", package: "MPVKit"),
            ],
            // mpv's C callback interop is not strict-concurrency-clean; the
            // downgrade is scoped to the app target only.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
```

- [ ] **Step 2: Write the app entry point**

`Sources/RiptideApp/RiptideApp.swift`:

```swift
import SwiftUI
import StreamCore

@main
struct Riptide: App {
    var body: some Scene {
        WindowGroup {
            Text("Riptide — StreamCore \(StreamCore.version)")
                .frame(minWidth: 500, minHeight: 350)
        }
    }
}
```

- [ ] **Step 3: Build and test**

Run: `swift build` (first run resolves + downloads MPVKit xcframeworks — slow, one-time)
Expected: `Build complete!`
Run: `swift test`
Expected: `Executed 24 tests, with 0 failures` (StreamCore untouched)

- [ ] **Step 4: Commit**

```bash
git add Package.swift Package.resolved Sources/RiptideApp
git commit -m "feat: RiptideApp executable target with MPVKit dependency"
```

---

### Task 2: LibraryRefresher (StreamCore, TDD)

**Files:**
- Create: `Sources/StreamCore/Store/LibraryRefresher.swift`
- Test: `Tests/StreamCoreTests/LibraryRefresherTests.swift`

**Interfaces:**
- Consumes: `RealDebridClient.allTorrents()`, `LibraryStore.upsert/items/applyMatch`, `TMDBClient.searchMovie/searchTV` (all Plan 1).
- Produces (used by Task 6 LibraryModel):
  - `@MainActor public struct LibraryRefresher { public init(rd: RealDebridClient, tmdb: TMDBClient, store: LibraryStore) }`
  - `public func refresh() async throws -> RefreshSummary`
  - `public struct RefreshSummary: Equatable, Sendable { public var upsert: UpsertSummary; public var matched: Int; public var matchFailed: Int }`

- [ ] **Step 1: Write failing tests**

`Tests/StreamCoreTests/LibraryRefresherTests.swift`:

```swift
import XCTest
@testable import StreamCore

@MainActor
final class LibraryRefresherTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.setHandler(nil)
        super.tearDown()
    }

    private func makeRefresher(store: LibraryStore) -> LibraryRefresher {
        LibraryRefresher(rd: RealDebridClient(token: "T", session: .mocked()),
                         tmdb: TMDBClient(bearerToken: "K", session: .mocked()),
                         store: store)
    }

    private static func torrentJSON(id: String, filename: String,
                                    status: String = "downloaded") -> String {
        """
        {"id":"\(id)","filename":"\(filename)","hash":"h","bytes":100,"host":"rd",
         "split":2000,"progress":100,"status":"\(status)",
         "added":"2026-06-01T00:00:00.000Z","links":["https://real-debrid.com/d/\(id)"]}
        """
    }

    /// Routes by host: RD list call vs TMDB search calls.
    private static func handler(torrents: [String],
                                movieResults: String = #"{"results":[]}"#,
                                tvResults: String = #"{"results":[]}"#)
        -> @Sendable (URLRequest) -> MockURLProtocol.Stub {
        { request in
            let url = request.url!
            if url.host!.contains("real-debrid") {
                return .json("[\(torrents.joined(separator: ","))]")
            }
            if url.path.hasSuffix("/search/movie") { return .json(movieResults) }
            if url.path.hasSuffix("/search/tv") { return .json(tvResults) }
            return .json("{}", status: 404)
        }
    }

    func testMatchesMovieAndAppliesMetadata() async throws {
        let store = try LibraryStore.inMemory()
        MockURLProtocol.setHandler(Self.handler(
            torrents: [Self.torrentJSON(id: "T1", filename: "The.Matrix.1999.1080p.mkv")],
            movieResults: """
            {"results":[{"id":603,"title":"The Matrix","overview":"A hacker...",
              "poster_path":"/p.jpg","release_date":"1999-03-30","vote_average":8.2}]}
            """))
        let summary = try await makeRefresher(store: store).refresh()
        XCTAssertEqual(summary.matched, 1)
        XCTAssertEqual(summary.matchFailed, 0)
        let item = try XCTUnwrap(try store.items().first)
        XCTAssertEqual(item.tmdbID, 603)
        XCTAssertEqual(item.posterPath, "/p.jpg")
        XCTAssertEqual(item.mediaKind, "movie")
    }

    func testMatchesEpisodeViaTVSearch() async throws {
        let store = try LibraryStore.inMemory()
        MockURLProtocol.setHandler(Self.handler(
            torrents: [Self.torrentJSON(id: "T2", filename: "Breaking.Bad.S05E14.720p.mkv")],
            tvResults: """
            {"results":[{"id":1396,"name":"Breaking Bad","overview":"...",
              "poster_path":"/bb.jpg","first_air_date":"2008-01-20","vote_average":8.9}]}
            """))
        let summary = try await makeRefresher(store: store).refresh()
        XCTAssertEqual(summary.matched, 1)
        let item = try XCTUnwrap(try store.items().first)
        XCTAssertEqual(item.tmdbID, 1396)
        XCTAssertEqual(item.mediaKind, "episode")
    }

    func testNoResultsLeavesItemUnmatched() async throws {
        let store = try LibraryStore.inMemory()
        MockURLProtocol.setHandler(Self.handler(
            torrents: [Self.torrentJSON(id: "T3", filename: "Obscure.Home.Video.2024.mkv")]))
        let summary = try await makeRefresher(store: store).refresh()
        XCTAssertEqual(summary.matched, 0)
        XCTAssertEqual(summary.matchFailed, 1)
        let item = try XCTUnwrap(try store.items().first)
        XCTAssertNil(item.tmdbID)          // renders as plain file card
    }

    func testTMDBErrorIsBestEffortNotFatal() async throws {
        let store = try LibraryStore.inMemory()
        MockURLProtocol.setHandler { request in
            if request.url!.host!.contains("real-debrid") {
                return .json("[\(Self.torrentJSON(id: "T4", filename: "A.2020.mkv"))]")
            }
            return .json("{}", status: 500)   // TMDB down
        }
        let summary = try await makeRefresher(store: store).refresh()
        XCTAssertEqual(summary.matchFailed, 1)
        XCTAssertEqual(try store.items().count, 1)   // item survives
    }

    func testSkipsNonDownloadedTorrentsAndAlreadyMatched() async throws {
        let store = try LibraryStore.inMemory()
        // Seed a matched item so refresh must not re-match it.
        _ = try store.upsert(torrents: [TorrentListItem(
            id: "T5", filename: "The.Matrix.1999.mkv", bytes: 100, progress: 100,
            status: "downloaded", added: "2026-06-01T00:00:00.000Z",
            links: ["https://real-debrid.com/d/T5"], ended: nil)])
        try store.applyMatch(torrentID: "T5", tmdbID: 603, mediaKind: "movie",
                             posterPath: "/p.jpg", overview: "", rating: 8.2)

        nonisolated(unsafe) var tmdbCalls = 0
        MockURLProtocol.setHandler { request in
            if request.url!.host!.contains("real-debrid") {
                return .json("""
                [\(Self.torrentJSON(id: "T5", filename: "The.Matrix.1999.mkv")),
                 \(Self.torrentJSON(id: "T6", filename: "downloading.mkv", status: "downloading"))]
                """)
            }
            tmdbCalls += 1
            return .json(#"{"results":[]}"#)
        }
        let summary = try await makeRefresher(store: store).refresh()
        XCTAssertEqual(tmdbCalls, 0)                       // matched item not re-searched
        XCTAssertEqual(summary.matched, 0)
        XCTAssertEqual(Set(try store.items().map(\.torrentID)), ["T5"])  // T6 filtered out
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter LibraryRefresherTests`
Expected: compile error — `LibraryRefresher` doesn't exist.

- [ ] **Step 3: Implement**

`Sources/StreamCore/Store/LibraryRefresher.swift`:

```swift
import Foundation

public struct RefreshSummary: Equatable, Sendable {
    public var upsert: UpsertSummary
    public var matched: Int
    public var matchFailed: Int

    public init(upsert: UpsertSummary, matched: Int, matchFailed: Int) {
        self.upsert = upsert; self.matched = matched; self.matchFailed = matchFailed
    }
}

/// Full library sync: RD torrent list → store diff → TMDB match for unmatched
/// items. Matching is best-effort — any TMDB failure just leaves that item as
/// a plain (still playable) file card; refresh never throws for TMDB reasons.
@MainActor
public struct LibraryRefresher {
    let rd: RealDebridClient
    let tmdb: TMDBClient
    let store: LibraryStore

    public init(rd: RealDebridClient, tmdb: TMDBClient, store: LibraryStore) {
        self.rd = rd; self.tmdb = tmdb; self.store = store
    }

    public func refresh() async throws -> RefreshSummary {
        // Only finished torrents are streamable.
        let torrents = try await rd.allTorrents().filter { $0.status == "downloaded" }
        let upsert = try store.upsert(torrents: torrents)

        var matched = 0, failed = 0
        for item in try store.items() where item.tmdbID == nil {
            do {
                if item.mediaKind == "episode" {
                    guard let show = try await tmdb.searchTV(title: item.title,
                                                             year: item.year).first else {
                        failed += 1; continue
                    }
                    try store.applyMatch(torrentID: item.torrentID, tmdbID: show.id,
                                         mediaKind: "episode",
                                         posterPath: show.posterPath,
                                         overview: show.overview,
                                         rating: show.voteAverage)
                } else {
                    guard let movie = try await tmdb.searchMovie(title: item.title,
                                                                 year: item.year).first else {
                        failed += 1; continue
                    }
                    try store.applyMatch(torrentID: item.torrentID, tmdbID: movie.id,
                                         mediaKind: "movie",
                                         posterPath: movie.posterPath,
                                         overview: movie.overview,
                                         rating: movie.voteAverage)
                }
                matched += 1
            } catch {
                // ponytail: per-item error detail dropped; summary count is enough
                // for v1's "N items unmatched" toast. Item stays as a file card.
                failed += 1
            }
        }
        return RefreshSummary(upsert: upsert, matched: matched, matchFailed: failed)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter LibraryRefresherTests`
Expected: PASS (5 tests). Then `swift test` — 29 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/StreamCore/Store/LibraryRefresher.swift Tests/StreamCoreTests/LibraryRefresherTests.swift
git commit -m "feat: library refresh pipeline (RD sync + TMDB matching)"
```

---

### Task 3: Keychain, AppSettings, SettingsView

**Files:**
- Create: `Sources/RiptideApp/Settings/KeychainStore.swift`
- Create: `Sources/RiptideApp/Settings/AppSettings.swift`
- Create: `Sources/RiptideApp/Settings/SettingsView.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces (used by Tasks 5-7):
  - `struct KeychainStore { init(service: String = "com.northlab.riptide"); func get(_ account: String) -> String?; func set(_ value: String, account: String); func delete(account: String) }`
  - `@Observable final class AppSettings { static let shared: AppSettings; private(set) var rdToken: String; private(set) var tmdbToken: String; private(set) var openSubsKey: String; var isConfigured: Bool; func save(rdToken: String, tmdbToken: String, openSubsKey: String) }`
  - `struct SettingsView: View` — form with three secure fields + Save.

- [ ] **Step 1: Write KeychainStore**

`Sources/RiptideApp/Settings/KeychainStore.swift`:

```swift
import Foundation
import Security

/// Thin wrapper over SecItem generic passwords. No error surface: a missing
/// key reads as nil and the settings UI treats empty as unconfigured.
struct KeychainStore {
    let service: String
    init(service: String = "com.northlab.riptide") { self.service = service }

    private func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func get(_ account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ value: String, account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
        var add = baseQuery(account)
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    func delete(account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }
}
```

- [ ] **Step 2: Write AppSettings**

`Sources/RiptideApp/Settings/AppSettings.swift`:

```swift
import Foundation
import Observation

@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let keychain = KeychainStore()
    private(set) var rdToken: String
    private(set) var tmdbToken: String
    private(set) var openSubsKey: String

    init() {
        rdToken = keychain.get("rd-token") ?? ""
        tmdbToken = keychain.get("tmdb-token") ?? ""
        openSubsKey = keychain.get("opensubtitles-key") ?? ""
    }

    /// RD + TMDB are required for the library; OpenSubtitles is optional.
    var isConfigured: Bool { !rdToken.isEmpty && !tmdbToken.isEmpty }

    func save(rdToken: String, tmdbToken: String, openSubsKey: String) {
        self.rdToken = rdToken.trimmingCharacters(in: .whitespacesAndNewlines)
        self.tmdbToken = tmdbToken.trimmingCharacters(in: .whitespacesAndNewlines)
        self.openSubsKey = openSubsKey.trimmingCharacters(in: .whitespacesAndNewlines)
        keychain.set(self.rdToken, account: "rd-token")
        keychain.set(self.tmdbToken, account: "tmdb-token")
        keychain.set(self.openSubsKey, account: "opensubtitles-key")
    }
}
```

- [ ] **Step 3: Write SettingsView**

`Sources/RiptideApp/Settings/SettingsView.swift`:

```swift
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var rdToken = AppSettings.shared.rdToken
    @State private var tmdbToken = AppSettings.shared.tmdbToken
    @State private var openSubsKey = AppSettings.shared.openSubsKey

    var body: some View {
        Form {
            Section("Real-Debrid") {
                SecureField("API token", text: $rdToken)
                Link("Get your token at real-debrid.com/apitoken",
                     destination: URL(string: "https://real-debrid.com/apitoken")!)
                    .font(.caption)
            }
            Section("TMDB (posters & metadata)") {
                SecureField("API Read Access Token (v4)", text: $tmdbToken)
                Link("Create a free key at themoviedb.org/settings/api",
                     destination: URL(string: "https://www.themoviedb.org/settings/api")!)
                    .font(.caption)
            }
            Section("OpenSubtitles (optional)") {
                SecureField("API key", text: $openSubsKey)
                Link("Create a free key at opensubtitles.com/consumers",
                     destination: URL(string: "https://www.opensubtitles.com/en/consumers")!)
                    .font(.caption)
            }
            HStack {
                Spacer()
                Button("Save") {
                    AppSettings.shared.save(rdToken: rdToken, tmdbToken: tmdbToken,
                                            openSubsKey: openSubsKey)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(rdToken.isEmpty || tmdbToken.isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding(.bottom, 12)
    }
}
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: `Build complete!` (UI not yet reachable; wired in Task 6.)

- [ ] **Step 5: Commit**

```bash
git add Sources/RiptideApp/Settings
git commit -m "feat: Keychain-backed settings with entry form"
```

---

### Task 4: MPV Player Core (controller + SwiftUI bridge)

**Files:**
- Create: `Sources/RiptideApp/Player/MetalLayer.swift`
- Create: `Sources/RiptideApp/Player/MPVPlayerController.swift`
- Create: `Sources/RiptideApp/Player/PlayerModel.swift`
- Create: `Sources/RiptideApp/Player/MPVPlayerView.swift`

**Interfaces:**
- Consumes: MPVKit (`import Libmpv`), `LibraryStore.saveProgress` (Plan 1).
- Produces (used by Task 5 UI):
  - `enum PlayerEvent { case position(Double), duration(Double), paused(Bool), buffering(Bool), cacheTime(Double), tracksChanged([MPVTrack]), ended }`
  - `struct MPVTrack: Identifiable, Equatable { let id: Int; let type: String; let lang: String?; let title: String?; let selected: Bool }` — `type` is `"audio"` or `"sub"`.
  - `final class MPVPlayerController: NSViewController` — `func loadFile(_ url: URL, startAt: Double?)`, `func togglePause()`, `func seek(to seconds: Double)`, `func setVolume(_ volume: Double)`, `func setAudioTrack(id: Int)`, `func setSubtitleTrack(id: Int?)`, `func addSubtitle(path: String)`, `var onEvent: ((PlayerEvent) -> Void)?`
  - `@Observable @MainActor final class PlayerModel` — published `position, duration, paused, buffering, cacheTime, audioTracks, subTracks`; `func attach(controller:)`; user intents mirroring the controller; autosaves progress every 5s.
  - `struct MPVPlayerView: NSViewControllerRepresentable` — `init(model: PlayerModel, url: URL, startAt: Double?)`.

- [ ] **Step 1: Write MetalLayer (MoltenVK workarounds, from MPVKit demo)**

`Sources/RiptideApp/Player/MetalLayer.swift`:

```swift
import Foundation
import AppKit

// Adapted from MPVKit's macOS demo (Demo/Demo-macOS/Player/Metal/MetalLayer.swift).
// Both overrides work around MoltenVK behaviors; see
// https://github.com/mpv-player/mpv/pull/13651
final class MetalLayer: CAMetalLayer {
    // MoltenVK momentarily forces drawableSize to 1x1 to complete presentation;
    // letting that through causes flicker and can leave the size stuck at 1x1.
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }

    // EDR activation only takes effect from the main thread.
    override var wantsExtendedDynamicRangeContent: Bool {
        get { super.wantsExtendedDynamicRangeContent }
        set {
            if Thread.isMainThread {
                super.wantsExtendedDynamicRangeContent = newValue
            } else {
                DispatchQueue.main.sync {
                    super.wantsExtendedDynamicRangeContent = newValue
                }
            }
        }
    }
}
```

- [ ] **Step 2: Write MPVPlayerController**

`Sources/RiptideApp/Player/MPVPlayerController.swift`:

```swift
import AppKit
import Libmpv

enum PlayerEvent {
    case position(Double)
    case duration(Double)
    case paused(Bool)
    case buffering(Bool)
    case cacheTime(Double)
    case tracksChanged([MPVTrack])
    case ended
    case error(String)     // terminal load/decode failure, surfaced in the window
}

struct MPVTrack: Identifiable, Equatable {
    let id: Int
    let type: String      // "audio" | "sub" | "video"
    let lang: String?
    let title: String?
    let selected: Bool

    var label: String {
        let name = [title, lang].compactMap { $0 }.joined(separator: " · ")
        return name.isEmpty ? "Track \(id)" : name
    }
}

/// mpv host view controller. Render path and lifecycle adapted from MPVKit's
/// macOS demo (MPVMetalViewController.swift): CAMetalLayer handed to mpv as
/// `wid`, vo=gpu-next over MoltenVK, wakeup-callback event loop drained on a
/// serial queue.
final class MPVPlayerController: NSViewController {
    var metalLayer = MetalLayer()
    var mpv: OpaquePointer!
    var onEvent: ((PlayerEvent) -> Void)?
    private lazy var queue = DispatchQueue(label: "mpv", qos: .userInitiated)

    override func loadView() {
        view = NSView(frame: .init(x: 0, y: 0, width: 1280, height: 720))
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        metalLayer.frame = view.frame
        metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = NSColor.black.cgColor
        view.layer = metalLayer
        view.wantsLayer = true
        setupMpv()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard let window = view.window else { return }
        let scale = window.screen?.backingScaleFactor ?? 2
        let size = view.bounds.size
        metalLayer.frame = CGRect(origin: .zero, size: size)
        metalLayer.drawableSize = CGSize(width: size.width * scale,
                                         height: size.height * scale)
    }

    private func setupMpv() {
        mpv = mpv_create()
        guard mpv != nil else { fatalError("mpv_create failed") }

        checkError(mpv_request_log_messages(mpv, "warn"))
        checkError(mpv_set_option_string(mpv, "input-media-keys", "yes"))
        checkError(mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &metalLayer))
        checkError(mpv_set_option_string(mpv, "vo", "gpu-next"))
        checkError(mpv_set_option_string(mpv, "gpu-api", "vulkan"))
        checkError(mpv_set_option_string(mpv, "gpu-context", "moltenvk"))
        checkError(mpv_set_option_string(mpv, "hwdec", "videotoolbox"))
        checkError(mpv_set_option_string(mpv, "ytdl", "no"))
        checkError(mpv_set_option_string(mpv, "keep-open", "yes"))

        checkError(mpv_initialize(mpv))

        mpv_observe_property(mpv, 0, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "paused-for-cache", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "demuxer-cache-time", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "eof-reached", MPV_FORMAT_FLAG)

        mpv_set_wakeup_callback(mpv, { ctx in
            guard let ctx else { return }
            let controller = Unmanaged<MPVPlayerController>.fromOpaque(ctx).takeUnretainedValue()
            controller.readEvents()
        }, Unmanaged.passRetained(self).toOpaque())
    }

    // MARK: Commands

    func loadFile(_ url: URL, startAt: Double? = nil) {
        var args = [url.absoluteString, "replace", "-1"]
        if let startAt, startAt > 1 {
            args.append("start=\(Int(startAt))")
        }
        command("loadfile", args: args)
    }

    func togglePause() {
        var paused: Int32 = 0
        mpv_get_property(mpv, "pause", MPV_FORMAT_FLAG, &paused)
        setFlag("pause", paused == 0)
    }

    func seek(to seconds: Double) {
        command("seek", args: [String(seconds), "absolute"])
    }

    func setVolume(_ volume: Double) {
        var v = min(max(volume, 0), 100)
        mpv_set_property(mpv, "volume", MPV_FORMAT_DOUBLE, &v)
    }

    func setAudioTrack(id: Int) {
        mpv_set_property_string(mpv, "aid", String(id))
    }

    /// nil disables subtitles.
    func setSubtitleTrack(id: Int?) {
        mpv_set_property_string(mpv, "sid", id.map(String.init) ?? "no")
    }

    func addSubtitle(path: String) {
        command("sub-add", args: [path, "select"])
    }

    private func setFlag(_ name: String, _ flag: Bool) {
        guard mpv != nil else { return }
        var data: Int32 = flag ? 1 : 0
        mpv_set_property(mpv, name, MPV_FORMAT_FLAG, &data)
    }

    private func command(_ command: String, args: [String?] = []) {
        guard mpv != nil else { return }
        var strArgs = args
        strArgs.insert(command, at: 0)
        strArgs.append(nil)
        var cargs = strArgs.map { $0.flatMap { UnsafePointer<CChar>(strdup($0)) } }
        defer { for ptr in cargs where ptr != nil { free(UnsafeMutablePointer(mutating: ptr!)) } }
        checkError(mpv_command(mpv, &cargs))
    }

    // MARK: Property reads

    private func getDouble(_ name: String) -> Double {
        guard mpv != nil else { return 0 }
        var data = Double()
        mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &data)
        return data
    }

    private func getInt(_ name: String) -> Int {
        guard mpv != nil else { return 0 }
        var data = Int64()
        mpv_get_property(mpv, name, MPV_FORMAT_INT64, &data)
        return Int(data)
    }

    private func getString(_ name: String) -> String? {
        guard mpv != nil else { return nil }
        guard let cstr = mpv_get_property_string(mpv, name) else { return nil }
        defer { mpv_free(cstr) }
        return String(cString: cstr)
    }

    private func getFlag(_ name: String) -> Bool {
        guard mpv != nil else { return false }
        var data: Int32 = 0
        mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &data)
        return data != 0
    }

    /// Enumerates track-list via sub-properties (guaranteed stable interface;
    /// avoids MPV_FORMAT_NODE traversal).
    private func currentTracks() -> [MPVTrack] {
        let count = getInt("track-list/count")
        return (0..<count).map { i in
            MPVTrack(id: getInt("track-list/\(i)/id"),
                     type: getString("track-list/\(i)/type") ?? "",
                     lang: getString("track-list/\(i)/lang"),
                     title: getString("track-list/\(i)/title"),
                     selected: getFlag("track-list/\(i)/selected"))
        }
    }

    // MARK: Event loop

    private func readEvents() {
        queue.async { [weak self] in
            guard let self else { return }
            while self.mpv != nil {
                guard let event = mpv_wait_event(self.mpv, 0),
                      event.pointee.event_id != MPV_EVENT_NONE else { break }

                switch event.pointee.event_id {
                case MPV_EVENT_PROPERTY_CHANGE:
                    let dataOpaquePtr = OpaquePointer(event.pointee.data)
                    guard let property = UnsafePointer<mpv_event_property>(dataOpaquePtr)?.pointee else { break }
                    self.handlePropertyChange(property)
                case MPV_EVENT_FILE_LOADED:
                    let tracks = self.currentTracks()
                    let duration = self.getDouble("duration")
                    self.emit(.tracksChanged(tracks))
                    self.emit(.duration(duration))
                case MPV_EVENT_END_FILE:
                    // Spec: mpv load failures surface in the player window.
                    if let end = UnsafePointer<mpv_event_end_file>(OpaquePointer(event.pointee.data))?.pointee,
                       end.reason == MPV_END_FILE_REASON_ERROR {
                        self.emit(.error(String(cString: mpv_error_string(end.error))))
                    } else {
                        self.emit(.ended)
                    }
                case MPV_EVENT_SHUTDOWN:
                    if self.mpv != nil {
                        mpv_terminate_destroy(self.mpv)
                        self.mpv = nil
                    }
                default:
                    break
                }
            }
        }
    }

    private func handlePropertyChange(_ property: mpv_event_property) {
        let name = String(cString: property.name)
        switch name {
        case "time-pos":
            guard let value = UnsafePointer<Double>(OpaquePointer(property.data))?.pointee else { return }
            emit(.position(value))
        case "duration":
            guard let value = UnsafePointer<Double>(OpaquePointer(property.data))?.pointee else { return }
            emit(.duration(value))
        case "pause":
            guard let value = UnsafePointer<Int32>(OpaquePointer(property.data))?.pointee else { return }
            emit(.paused(value != 0))
        case "paused-for-cache":
            guard let value = UnsafePointer<Int32>(OpaquePointer(property.data))?.pointee else { return }
            emit(.buffering(value != 0))
        case "demuxer-cache-time":
            guard let value = UnsafePointer<Double>(OpaquePointer(property.data))?.pointee else { return }
            emit(.cacheTime(value))
        case "eof-reached":
            guard let value = UnsafePointer<Int32>(OpaquePointer(property.data))?.pointee,
                  value != 0 else { return }
            emit(.ended)
        default:
            break
        }
    }

    private func emit(_ event: PlayerEvent) {
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(event)
        }
    }

    deinit {
        if mpv != nil {
            mpv_set_wakeup_callback(mpv, nil, nil)
            queue.sync {
                if self.mpv != nil {
                    mpv_terminate_destroy(self.mpv)
                    self.mpv = nil
                }
            }
            Unmanaged.passUnretained(self).release()
        }
    }

    private func checkError(_ status: CInt) {
        if status < 0 {
            NSLog("mpv error: \(String(cString: mpv_error_string(status)))")
        }
    }
}
```

- [ ] **Step 3: Write PlayerModel**

`Sources/RiptideApp/Player/PlayerModel.swift`:

```swift
import Foundation
import Observation
import StreamCore

/// Observable playback state + progress autosave. One instance per player window.
@Observable
@MainActor
final class PlayerModel {
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var paused = false
    private(set) var buffering = false
    private(set) var cacheTime: Double = 0
    private(set) var tracks: [MPVTrack] = []
    private(set) var playbackError: String?

    var audioTracks: [MPVTrack] { tracks.filter { $0.type == "audio" } }
    var subTracks: [MPVTrack] { tracks.filter { $0.type == "sub" } }

    private weak var controller: MPVPlayerController?
    private let store: LibraryStore
    private let itemKey: String
    private var lastSaved: Double = 0

    init(store: LibraryStore, itemKey: String) {
        self.store = store
        self.itemKey = itemKey
    }

    func attach(_ controller: MPVPlayerController) {
        self.controller = controller
        controller.onEvent = { [weak self] event in
            self?.handle(event)
        }
    }

    private func handle(_ event: PlayerEvent) {
        switch event {
        case .position(let t):
            position = t
            if abs(t - lastSaved) >= 5 {          // spec: autosave every 5 s
                lastSaved = t
                try? store.saveProgress(itemKey: itemKey, position: t, duration: duration)
            }
        case .duration(let d):   duration = d
        case .paused(let p):     paused = p
        case .buffering(let b):  buffering = b
        case .cacheTime(let t):  cacheTime = t
        case .tracksChanged(let t): tracks = t
        case .ended:
            if duration > 0 {
                try? store.saveProgress(itemKey: itemKey, position: duration, duration: duration)
            }
        case .error(let message):
            playbackError = message
        }
    }

    /// Flush current position (window closing, app quitting).
    func flushProgress() {
        guard position > 0, duration > 0 else { return }
        try? store.saveProgress(itemKey: itemKey, position: position, duration: duration)
    }

    // MARK: User intents

    func togglePause() { controller?.togglePause() }
    func seek(to seconds: Double) { controller?.seek(to: seconds) }
    func setVolume(_ v: Double) { controller?.setVolume(v) }
    func setAudioTrack(_ id: Int) { controller?.setAudioTrack(id: id) }
    func setSubtitleTrack(_ id: Int?) { controller?.setSubtitleTrack(id: id) }
    func addSubtitle(path: String) { controller?.addSubtitle(path: path) }
}
```

- [ ] **Step 4: Write MPVPlayerView**

`Sources/RiptideApp/Player/MPVPlayerView.swift`:

```swift
import SwiftUI

struct MPVPlayerView: NSViewControllerRepresentable {
    let model: PlayerModel
    let url: URL
    let startAt: Double?

    func makeNSViewController(context: Context) -> MPVPlayerController {
        let controller = MPVPlayerController()
        model.attach(controller)
        // Defer load until the view (and mpv) exist.
        DispatchQueue.main.async {
            controller.loadFile(url, startAt: startAt)
        }
        return controller
    }

    func updateNSViewController(_ controller: MPVPlayerController, context: Context) {}
}
```

- [ ] **Step 5: Build and commit**

Run: `swift build`
Expected: `Build complete!` (runtime behavior verified in Task 7).

```bash
git add Sources/RiptideApp/Player
git commit -m "feat: MPVKit player core (controller, model, SwiftUI bridge)"
```

---

### Task 5: Player Window UI

**Files:**
- Create: `Sources/RiptideApp/Player/PlayItem.swift`
- Create: `Sources/RiptideApp/Player/PlayerWindowView.swift`
- Create: `Sources/RiptideApp/Player/SubtitleSearchSheet.swift`

**Interfaces:**
- Consumes: `PlayerModel`, `MPVPlayerView`, `MPVTrack` (Task 4); `OpenSubtitlesClient`, `SubtitleResult` (Plan 1); `AppSettings` (Task 3); `LibraryStore` (Plan 1).
- Produces (used by Task 6):
  - `struct PlayItem: Identifiable, Hashable, Codable { var id: String { itemKey }; let itemKey: String; let title: String; let url: URL; let resumeFrom: Double?; let subtitleQuery: String; let season: Int?; let episode: Int? }`
  - `struct PlayerWindowView: View` — `init(item: PlayItem, store: LibraryStore)`.

- [ ] **Step 1: Write PlayItem**

`Sources/RiptideApp/Player/PlayItem.swift`:

```swift
import Foundation

/// Everything a player window needs, passed through SwiftUI's
/// WindowGroup(for:) value routing (hence Codable + Hashable).
struct PlayItem: Identifiable, Hashable, Codable {
    var id: String { itemKey }
    let itemKey: String            // "<torrentID>#<fileIndex>"
    let title: String
    let url: URL                   // unrestricted direct stream URL
    let resumeFrom: Double?
    let subtitleQuery: String      // parsed title for OpenSubtitles search
    let season: Int?
    let episode: Int?
}
```

- [ ] **Step 2: Write PlayerWindowView**

`Sources/RiptideApp/Player/PlayerWindowView.swift`:

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
        .onHover { hovering in
            controlsVisible = hovering || model.paused
        }
        .onContinuousHover { phase in
            if case .active = phase { controlsVisible = true }
        }
        .navigationTitle(item.title)
        .onDisappear { model.flushProgress() }
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
```

- [ ] **Step 3: Write SubtitleSearchSheet**

`Sources/RiptideApp/Player/SubtitleSearchSheet.swift`:

```swift
import SwiftUI
import StreamCore

struct SubtitleSearchSheet: View {
    let season: Int?
    let episode: Int?
    let onPicked: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query: String
    @State private var results: [SubtitleResult] = []
    @State private var status: String?
    @State private var searching = false

    init(query: String, season: Int?, episode: Int?, onPicked: @escaping (String) -> Void) {
        _query = State(initialValue: query)
        self.season = season
        self.episode = episode
        self.onPicked = onPicked
    }

    private var client: OpenSubtitlesClient? {
        let key = AppSettings.shared.openSubsKey
        return key.isEmpty ? nil : OpenSubtitlesClient(apiKey: key)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("Search subtitles", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await search() } }
                Button("Search") { Task { await search() } }
                    .disabled(searching || query.isEmpty)
            }
            if let status {
                Text(status).foregroundStyle(.secondary)
            }
            List(results) { result in
                Button(action: { Task { await download(result) } }) {
                    VStack(alignment: .leading) {
                        Text(result.release).lineLimit(1)
                        Text(result.language).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }
            }
        }
        .padding()
        .frame(width: 420, height: 380)
        .task { await search() }
    }

    private func search() async {
        guard let client else {
            status = "Add an OpenSubtitles API key in Settings first."
            return
        }
        searching = true
        defer { searching = false }
        do {
            results = try await client.search(query: query, season: season, episode: episode)
            status = results.isEmpty ? "No results." : nil
        } catch {
            status = "Search failed: \(error)"
        }
    }

    private func download(_ result: SubtitleResult) async {
        guard let client else { return }
        do {
            let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Riptide/subs", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = try await client.downloadSubtitle(fileID: result.fileID, into: dir)
            onPicked(file.path)
            dismiss()
        } catch {
            status = "Download failed: \(error)"
        }
    }
}
```

- [ ] **Step 4: Build and commit**

Run: `swift build`
Expected: `Build complete!`

```bash
git add Sources/RiptideApp/Player
git commit -m "feat: player window with controls, track pickers, subtitle search"
```

---

### Task 6: Library UI + App Wiring

**Files:**
- Create: `Sources/RiptideApp/Library/LibraryModel.swift`
- Create: `Sources/RiptideApp/Library/LibraryViews.swift`
- Create: `Sources/RiptideApp/Library/ItemDetailView.swift`
- Modify: `Sources/RiptideApp/RiptideApp.swift` (replace placeholder)

**Interfaces:**
- Consumes: everything from Tasks 2-5 plus StreamCore (`LibraryStore`, `LibraryItem`, `WatchState`, `RealDebridClient.unrestrictLink`, `TMDB.imageURL`).
- Produces: complete app — main library window + player windows via `WindowGroup(for: PlayItem.self)`.

- [ ] **Step 1: Write LibraryModel**

`Sources/RiptideApp/Library/LibraryModel.swift`:

```swift
import Foundation
import Observation
import StreamCore

struct ShowGroup: Identifiable {
    let id: String            // lowercased show title
    let title: String
    let posterPath: String?
    let episodes: [LibraryItem]
}

struct ContinueEntry: Identifiable {
    var id: String { state.itemKey }
    let state: WatchState
    let item: LibraryItem
}

@Observable
@MainActor
final class LibraryModel {
    private(set) var items: [LibraryItem] = []
    private(set) var continueWatching: [ContinueEntry] = []
    private(set) var refreshing = false
    var searchText = ""
    var errorMessage: String?
    var needsAuth = false

    let store: LibraryStore

    init(store: LibraryStore) {
        self.store = store
        reload()
    }

    private var filtered: [LibraryItem] {
        guard !searchText.isEmpty else { return items }
        let q = searchText.lowercased()
        return items.filter {
            $0.title.lowercased().contains(q) || $0.filename.lowercased().contains(q)
        }
    }

    var movies: [LibraryItem] {
        filtered.filter { $0.mediaKind == "movie" && $0.tmdbID != nil }
    }

    var shows: [ShowGroup] {
        let episodes = filtered.filter { $0.mediaKind == "episode" }
        let grouped = Dictionary(grouping: episodes) { $0.title.lowercased() }
        return grouped.values.map { eps in
            let sorted = eps.sorted {
                ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0)
            }
            return ShowGroup(id: sorted[0].title.lowercased(),
                             title: sorted[0].title,
                             posterPath: sorted.compactMap(\.posterPath).first,
                             episodes: sorted)
        }
        .sorted { $0.title < $1.title }
    }

    var unmatched: [LibraryItem] {
        filtered.filter { $0.tmdbID == nil && $0.mediaKind == "movie" }
    }

    func reload() {
        items = (try? store.items()) ?? []
        let states = (try? store.continueWatching()) ?? []
        continueWatching = states.compactMap { state in
            let torrentID = String(state.itemKey.split(separator: "#")[0])
            guard let item = items.first(where: { $0.torrentID == torrentID }) else { return nil }
            return ContinueEntry(state: state, item: item)
        }
    }

    func refresh() async {
        let settings = AppSettings.shared
        guard settings.isConfigured else { needsAuth = true; return }
        refreshing = true
        defer { refreshing = false; reload() }
        do {
            let refresher = LibraryRefresher(
                rd: RealDebridClient(token: settings.rdToken),
                tmdb: TMDBClient(bearerToken: settings.tmdbToken),
                store: store)
            let summary = try await refresher.refresh()
            errorMessage = summary.matchFailed > 0
                ? "\(summary.matchFailed) item(s) could not be matched on TMDB." : nil
        } catch let e as RealDebridError where e == .unauthorized {
            needsAuth = true
        } catch {
            errorMessage = "Refresh failed: \(error)"
        }
    }

    /// Unrestrict and build the PlayItem for one file of a library item.
    func playItem(for item: LibraryItem, fileIndex: Int) async throws -> PlayItem {
        let settings = AppSettings.shared
        let rd = RealDebridClient(token: settings.rdToken)
        let link = item.links[fileIndex]
        let unrestricted = try await rd.unrestrictLink(link)
        guard let url = unrestricted.directURL else { throw RealDebridError.badResponse }
        let itemKey = "\(item.torrentID)#\(fileIndex)"
        let resume = (try? store.continueWatching())?
            .first { $0.itemKey == itemKey }?.positionSeconds
        return PlayItem(itemKey: itemKey,
                        title: item.title,
                        url: url,
                        resumeFrom: resume,
                        subtitleQuery: item.title,
                        season: item.season,
                        episode: item.episode)
    }
}
```

- [ ] **Step 2: Write LibraryViews (shelves, cards, sidebar)**

`Sources/RiptideApp/Library/LibraryViews.swift`:

```swift
import SwiftUI
import StreamCore

enum SidebarSection: String, CaseIterable, Identifiable {
    case continueWatching = "Continue Watching"
    case movies = "Movies"
    case shows = "TV Shows"
    case files = "Other Files"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .continueWatching: "play.circle"
        case .movies: "film"
        case .shows: "tv"
        case .files: "doc"
        }
    }
}

struct LibraryRootView: View {
    @State private var model: LibraryModel
    @State private var selection: SidebarSection = .movies
    @State private var showSettings = false

    init(store: LibraryStore) {
        _model = State(initialValue: LibraryModel(store: store))
    }

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.icon).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            detailView
                .searchable(text: $model.searchText, placement: .toolbar)
                .toolbar {
                    ToolbarItem {
                        Button(action: { Task { await model.refresh() } }) {
                            if model.refreshing { ProgressView().controlSize(.small) }
                            else { Image(systemName: "arrow.clockwise") }
                        }
                        .disabled(model.refreshing)
                    }
                    ToolbarItem {
                        Button(action: { showSettings = true }) {
                            Image(systemName: "gearshape")
                        }
                    }
                }
        }
        .sheet(isPresented: $showSettings, onDismiss: { Task { await model.refresh() } }) {
            SettingsView()
        }
        .task {
            if !AppSettings.shared.isConfigured { showSettings = true }
            else if model.items.isEmpty { await model.refresh() }
        }
        .alert("Real-Debrid authorization failed", isPresented: $model.needsAuth) {
            Button("Open Settings") { showSettings = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your Real-Debrid API token is missing or expired.")
        }
        .environment(model)
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .continueWatching: ContinueWatchingGrid()
        case .movies: MovieGrid()
        case .shows: ShowsList()
        case .files: FileList()
        }
    }
}

private let posterColumns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 16)]

struct MovieGrid: View {
    @Environment(LibraryModel.self) private var model

    var body: some View {
        ScrollView {
            LazyVGrid(columns: posterColumns, spacing: 20) {
                ForEach(model.movies, id: \.torrentID) { item in
                    NavigationLink(destination: ItemDetailView(item: item)) {
                        PosterCard(title: item.title, subtitle: item.year.map(String.init),
                                   posterPath: item.posterPath)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .overlay {
            if model.movies.isEmpty {
                ContentUnavailableView("No movies yet",
                                       systemImage: "film",
                                       description: Text("Refresh to sync your Real-Debrid library."))
            }
        }
    }
}

struct ShowsList: View {
    @Environment(LibraryModel.self) private var model

    var body: some View {
        ScrollView {
            LazyVGrid(columns: posterColumns, spacing: 20) {
                ForEach(model.shows) { show in
                    NavigationLink(destination: ShowDetailView(show: show)) {
                        PosterCard(title: show.title,
                                   subtitle: "\(show.episodes.count) episode(s)",
                                   posterPath: show.posterPath)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .overlay {
            if model.shows.isEmpty {
                ContentUnavailableView("No TV shows yet", systemImage: "tv",
                                       description: Text("Refresh to sync your Real-Debrid library."))
            }
        }
    }
}

struct ContinueWatchingGrid: View {
    @Environment(LibraryModel.self) private var model

    var body: some View {
        ScrollView {
            LazyVGrid(columns: posterColumns, spacing: 20) {
                ForEach(model.continueWatching) { entry in
                    PlayableCard(item: entry.item,
                                 fileIndex: fileIndex(of: entry),
                                 progress: entry.state.durationSeconds > 0
                                     ? entry.state.positionSeconds / entry.state.durationSeconds : 0)
                }
            }
            .padding()
        }
        .overlay {
            if model.continueWatching.isEmpty {
                ContentUnavailableView("Nothing in progress", systemImage: "play.circle",
                                       description: Text("Movies you start watching appear here."))
            }
        }
    }

    private func fileIndex(of entry: ContinueEntry) -> Int {
        Int(entry.state.itemKey.split(separator: "#").last.map(String.init) ?? "0") ?? 0
    }
}

struct FileList: View {
    @Environment(LibraryModel.self) private var model

    var body: some View {
        List(model.unmatched, id: \.torrentID) { item in
            PlayableFileRow(item: item)
        }
        .overlay {
            if model.unmatched.isEmpty {
                ContentUnavailableView("No unmatched files", systemImage: "doc",
                                       description: Text("Files TMDB can't identify appear here — still playable."))
            }
        }
    }
}

struct PosterCard: View {
    let title: String
    let subtitle: String?
    let posterPath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: posterPath.map { TMDB.imageURL(path: $0) }) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "film").font(.largeTitle).foregroundStyle(.secondary)
                }
            }
            .frame(height: 240)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(title).font(.callout.weight(.medium)).lineLimit(1)
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Card that plays directly on click (Continue Watching).
struct PlayableCard: View {
    @Environment(LibraryModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let item: LibraryItem
    let fileIndex: Int
    let progress: Double
    @State private var busy = false

    var body: some View {
        Button(action: { Task { await play() } }) {
            VStack(alignment: .leading, spacing: 6) {
                PosterCard(title: item.title,
                           subtitle: item.season.map { "S\($0)E\(item.episode ?? 0)" },
                           posterPath: item.posterPath)
                ProgressView(value: progress).controlSize(.small)
            }
            .overlay { if busy { ProgressView() } }
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private func play() async {
        busy = true
        defer { busy = false }
        if let playItem = try? await model.playItem(for: item, fileIndex: fileIndex) {
            openWindow(value: playItem)
        }
    }
}

/// Plain file row with a play button (unmatched items — spec's fallback card).
struct PlayableFileRow: View {
    @Environment(LibraryModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let item: LibraryItem
    @State private var busy = false

    var body: some View {
        HStack {
            Image(systemName: "doc.fill").foregroundStyle(.secondary)
            VStack(alignment: .leading) {
                Text(item.filename).lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: item.sizeBytes,
                                               countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: { Task { await play() } }) {
                if busy { ProgressView().controlSize(.small) }
                else { Image(systemName: "play.fill") }
            }
            .disabled(busy || item.links.isEmpty)
        }
        .padding(.vertical, 2)
    }

    private func play() async {
        busy = true
        defer { busy = false }
        if let playItem = try? await model.playItem(for: item, fileIndex: 0) {
            openWindow(value: playItem)
        }
    }
}
```

- [ ] **Step 3: Write ItemDetailView (movie detail + show detail)**

`Sources/RiptideApp/Library/ItemDetailView.swift`:

```swift
import SwiftUI
import StreamCore

struct ItemDetailView: View {
    @Environment(LibraryModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let item: LibraryItem
    @State private var busyIndex: Int?
    @State private var playError: String?

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 20) {
                AsyncImage(url: item.posterPath.map { TMDB.imageURL(path: $0) }) { image in
                    image.resizable().aspectRatio(contentMode: .fit)
                } placeholder: {
                    Rectangle().fill(.quaternary)
                }
                .frame(width: 220, height: 330)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 10) {
                    Text(item.title).font(.largeTitle.bold())
                    HStack(spacing: 12) {
                        if let year = item.year { Text(String(year)) }
                        if let quality = item.quality { Text(quality.uppercased()) }
                        if let rating = item.rating {
                            Label(String(format: "%.1f", rating), systemImage: "star.fill")
                        }
                    }
                    .foregroundStyle(.secondary)

                    if let overview = item.overview, !overview.isEmpty {
                        Text(overview).frame(maxWidth: 520, alignment: .leading)
                    }

                    Divider().frame(maxWidth: 520)

                    // A torrent can hold several files; RD gives us opaque links,
                    // so label by index. ponytail: per-file names need a
                    // torrentInfo call — add when multi-file packs feel blind.
                    ForEach(Array(item.links.enumerated()), id: \.offset) { index, _ in
                        Button(action: { Task { await play(index) } }) {
                            HStack {
                                if busyIndex == index { ProgressView().controlSize(.small) }
                                else { Image(systemName: "play.fill") }
                                Text(item.links.count == 1 ? "Play" : "Play file \(index + 1)")
                            }
                        }
                        .disabled(busyIndex != nil)
                    }
                    if let playError {
                        Text(playError).foregroundStyle(.red).font(.callout)
                    }
                }
                Spacer()
            }
            .padding(24)
        }
        .navigationTitle(item.title)
    }

    private func play(_ index: Int) async {
        busyIndex = index
        defer { busyIndex = nil }
        do {
            let playItem = try await model.playItem(for: item, fileIndex: index)
            openWindow(value: playItem)
        } catch {
            playError = "Could not start stream: \(error)"
        }
    }
}

struct ShowDetailView: View {
    let show: ShowGroup

    private var seasons: [(number: Int, episodes: [LibraryItem])] {
        Dictionary(grouping: show.episodes) { $0.season ?? 0 }
            .map { (number: $0.key, episodes: $0.value) }
            .sorted { $0.number < $1.number }
    }

    var body: some View {
        List {
            ForEach(seasons, id: \.number) { season in
                Section("Season \(season.number)") {
                    ForEach(season.episodes, id: \.torrentID) { episode in
                        NavigationLink(destination: ItemDetailView(item: episode)) {
                            HStack {
                                Text("E\(episode.episode ?? 0)")
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text(episode.filename).lineLimit(1)
                                Spacer()
                                if let quality = episode.quality {
                                    Text(quality).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(show.title)
    }
}
```

- [ ] **Step 4: Rewrite the app entry point**

Replace `Sources/RiptideApp/RiptideApp.swift`:

```swift
import SwiftUI
import StreamCore

@main
struct Riptide: App {
    private let store: LibraryStore

    init() {
        do { store = try LibraryStore.onDisk() }
        catch { fatalError("Failed to open library store: \(error)") }
    }

    var body: some Scene {
        WindowGroup {
            LibraryRootView(store: store)
                .frame(minWidth: 900, minHeight: 600)
        }

        WindowGroup(for: PlayItem.self) { $item in
            if let item {
                PlayerWindowView(item: item, store: store)
                    .frame(minWidth: 800, minHeight: 450)
            }
        }
        .windowStyle(.hiddenTitleBar)
    }
}
```

- [ ] **Step 5: Build and commit**

Run: `swift build && swift test`
Expected: `Build complete!`, 29 tests green.

```bash
git add Sources/RiptideApp
git commit -m "feat: library shelves, detail views, and app wiring"
```

---

### Task 7: End-to-End Manual Verification + README

**Files:**
- Create: `README.md`

**Interfaces:**
- Consumes: the complete app.
- Produces: verified v1 + quickstart doc.

- [ ] **Step 1: Write README.md**

```markdown
# Riptide

Native macOS app that streams your Real-Debrid library with an embedded
mpv player (MKV, every codec) — a personal Infuse replacement.

## Requirements

- macOS 14+
- Real-Debrid premium account + [API token](https://real-debrid.com/apitoken)
- Free [TMDB API Read Access Token](https://www.themoviedb.org/settings/api) (posters/metadata)
- Optional: free [OpenSubtitles API key](https://www.opensubtitles.com/en/consumers)

## Run

    swift run RiptideApp

First launch opens Settings — paste your keys (stored in the macOS Keychain).
Hit refresh; your RD torrents appear as a poster library. Click to stream.

## Develop

    swift test          # StreamCore unit tests
    swift build         # includes the RiptideApp target

Licensing: uses MPVKit's LGPL build as a dynamic framework; do not switch
to the `MPVKit-GPL` product.
```

- [ ] **Step 2: Manual E2E checklist**

Run: `swift run RiptideApp` with real keys and verify each item. THIS REQUIRES THE HUMAN — the executor pauses here and asks the user to run through the checklist together:

1. First launch auto-opens Settings; Save disabled until RD + TMDB fields filled.
2. Refresh syncs RD library; posters appear for movies and shows; unmatched files land in Other Files and still play.
3. Playing an MKV opens a player window; video + audio play; seeking works (buffered region visible behind the slider).
4. Audio/subtitle menus list embedded tracks; switching works mid-play.
5. OpenSubtitles search returns results; picking one shows the subtitle.
6. Quit mid-movie → relaunch → Continue Watching shows the item with a progress bar → clicking resumes near the stopping point.
7. Watch a file to the end → it leaves Continue Watching.
8. Quit and relaunch offline (Wi-Fi off) → cached library still renders (play fails gracefully with an error message).

- [ ] **Step 3: Fix anything the checklist surfaces, then commit**

```bash
git add README.md
git commit -m "docs: README quickstart + E2E verification"
```

---

## Plan 2 Exit Criteria

- `swift build` clean; `swift test` 29 green (StreamCore only, still zero UI imports).
- Manual checklist items 1-8 all pass with real accounts.
- Branch `feat/plan-2-app` PR'd into main on github.com/northlabapps/riptide.

## Deferred (post-v1 backlog)

Per-file names in multi-file packs (needs `torrentInfo` call), episode-level
TMDB metadata (`episode()` client exists, unused), parser regex caching,
poster disk cache, keyboard shortcuts beyond space, auto-hiding cursor in
fullscreen, `pollUntil` transient-5xx hardening (also applies upstream in
Cascade).
