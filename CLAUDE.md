# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Riptide: a native macOS app (SwiftUI + AppKit) that streams a Real-Debrid
library through an embedded mpv player. Personal Infuse replacement — browse
RD torrents as a poster library, match against TMDB metadata, play any codec
via mpv, sync watch progress with Trakt.

## Commands

    swift build              # build everything (StreamCore + RiptideApp)
    swift test                # run all StreamCoreTests
    swift test --filter TestClassName/testMethodName   # single test
    scripts/run.sh             # build, codesign, and launch the app
    NOTARY_PROFILE=riptide scripts/package.sh   # release .app + DMG, notarized
    scripts/run-tv.sh          # xcodegen, build for tvOS simulator, install, launch
    cd RiptideTV && xcodegen generate && xcodebuild test -project RiptideTV.xcodeproj -scheme RiptideTV -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' CODE_SIGNING_ALLOWED=NO

Release builds land in `dist/` (gitignored), signed with the Developer ID
for team `YWM9Q6F35V`. The notarytool credentials live in the login Keychain
under profile `riptide` (created once via `xcrun notarytool store-credentials
riptide --apple-id <apple-id> --team-id YWM9Q6F35V` with an app-specific
password — run it in Terminal.app, the password prompt needs a real TTY).
Omit `NOTARY_PROFILE` for a signed-but-unnotarized local build; set
`VERSION=x.y.z` to bump `CFBundleShortVersionString`.

Always use `scripts/run.sh` instead of `swift run RiptideApp` — `swift run`
leaves the binary ad-hoc signed, so its signature hash changes on every
rebuild and macOS re-prompts for Keychain access each launch. The script
re-signs with a stable dev identity so "Always Allow" actually sticks.

Debug env vars (set before `scripts/run.sh`):
- `RIPTIDE_DEBUG_URL=<video url>` — opens a player window directly on launch.
- `RIPTIDE_MPV_LOG=<path>` — full mpv log capture.
- `RIPTIDE_DEBUG_SUB=<path.srt>` — auto-loads then deselects that subtitle
  shortly after playback starts (exercises sub-add without UI); also logs mpv
  track-list changes while set.
- `RIPTIDE_TRAKT_PROBE=1` — dumps Trakt playback-progress state.

## Architecture

Two targets, hard-separated:

- **StreamCore** (library target) — pure logic, no UI imports allowed. All
  networking clients, the release-name parser, and the SwiftData store live
  here. This is what's unit tested (`Tests/StreamCoreTests`).
- **RiptideApp** (executable target) — SwiftUI/AppKit UI, mpv playback
  integration, Keychain-backed settings. Depends on StreamCore + MPVKit.
  Downgraded to Swift language mode 5 (only this target) because mpv's C
  callback interop isn't strict-concurrency-clean.

### Data flow: RD → SwiftData → UI

`LibraryRefresher.refresh()` is the sync entry point:
1. Pull `rd.allTorrents()`, filter to `status == "downloaded"` with links.
2. Flatten each torrent into per-file `LibraryFileEntry` — single-file
   torrents map directly; multi-file packs call `torrentInfo` only when the
   cached entry count doesn't already match (`LibraryStore.entryCounts()`
   lets a fully-expanded pack skip that RPC on future refreshes).
3. `LibraryStore.upsert(entries:)` diffs against SwiftData (`LibraryItem`),
   parsing filenames via `ReleaseNameParser` on insert/update, and deletes
   orphaned items + their `WatchState` (both are `@Model` types in
   `Store/LibraryModels.swift`).
4. Grouped TMDB matching: one search per distinct `(kind, title, year)` so a
   23-episode pack costs a single API call. Matching is best-effort — a TMDB
   miss just leaves the item as an unmatched, still-playable file card
   (`tmdbID == nil`).

`LibraryStore` is `@MainActor` and synchronous — the single source of truth
for persisted state. The UI reads it through `LibraryModel`
(`RiptideApp/Library/LibraryModel.swift`), an `@Observable` view-model that
holds the displayed item/continue-watching collections and UI actions
(including the add-torrent sheet's drag/paste/toolbar entry points in
`AddTorrentSheet.swift`).
Pre-1.0 schema policy: if the on-disk SwiftData container fails to open
(schema changed), it's wiped and recreated rather than migrated.

### Player stack

`PlayerModel` (`@Observable`, per player window) owns playback intent and
autosave; `MPVPlayerController` (AppKit `NSViewController`) owns the actual
libmpv instance and its event loop. They talk through `PlayerEvent` — mpv
property-change callbacks land on a serial `DispatchQueue`, then get
dispatched back to `@MainActor` and translated into events `PlayerModel`
folds into published state (position, tracks, buffering, etc).

Render path (adapted from MPVKit's macOS demo): a `CAMetalLayer`-backed
`NSView` (`MPVVideoView`) is handed to mpv as `wid`; mpv renders via
`vo=gpu-next` / `gpu-api=vulkan` / `gpu-context=moltenvk` over MoltenVK. Note
the resize workaround in `MPVPlayerController.scheduleSurfaceAdopt()` — the
moltenvk gpu-context only re-reads the layer's `drawableSize` on VO reconfig
and has no resize event path, so a window resize is forced into a reconfig by
nudging `video-aspect-override` and reverting it.

`MPVPlayerController.shutdown()` is the only reliable teardown point (the mpv
wakeup callback retains `self`, so `deinit` can never fire while mpv is
alive) — it must be called explicitly when a player window closes.

Autosave/scrobble timing lives in `PlayerModel`: position saves to
`LibraryStore` every 5s of drift, and Trakt scrobbles fire on
start/pause/stop with progress clamped to Trakt's accepted range (skips
under 1%, skips pause above 80%).

### Networking clients (StreamCore)

`RealDebridClient`, `TMDBClient`, `OpenSubtitlesClient` are independent
`Sendable` structs; `TraktClient` is a `@MainActor final class` (it holds
mutable OAuth tokens). Each owns its own retry/error mapping.
`RealDebridClient` has the most machinery worth knowing:
- `send()` retries 429s up to `config.maxRetries` using `Retry-After` or a
  backoff, via an injectable `sleep` closure (tests substitute a no-op).
- `pollUntil()` / `resolveMagnet()` drive RD's async add → select-files →
  download → unrestrict flow, throwing on terminal failure statuses
  (`magnet_error`, `error`, `virus`, `dead`) or `config.pollTimeout`.
- `TorrentAdder` (separate struct) wraps that flow for the "add a
  magnet/.torrent" UI path: dedupes by infohash against the existing
  library, auto-selects video files (extension allowlist, skips samples),
  and reports `alreadyInLibrary` / `ready` / `downloading`. Editing an
  existing selection is delete + re-add + select — RD rejects `selectFiles`
  on an already-selected torrent.

`TraktSyncer.pull()` reconciles Trakt playback/watched history into the
local `WatchState` table — always newest-timestamp-wins, in both directions;
never overwrites local state that's newer than Trakt's.

### Settings & credentials

`AppSettings` (RD + TMDB tokens) and `TraktService` (Trakt OAuth device flow)
are `@Observable` singletons backed by `KeychainStore`, a thin `SecItem`
wrapper. No token ever touches UserDefaults or disk outside Keychain. RD +
TMDB are required for the library to function; OpenSubtitles and Trakt are
optional.

### RiptideTV (tvOS)

`RiptideTV/project.yml` (xcodegen) defines the tvOS app; `RiptideTV/RiptideTV.xcodeproj`
and `RiptideTV/build/` are gitignored and regenerated. Floor is tvOS 18
(StreamCore declares `.tvOS(.v18)`). Signing team comes from `RIPTIDE_TV_TEAM`.

Shared sources: files from `Sources/RiptideApp` are compiled into the TV
target by reference via the `includes` list in `project.yml`. A file listed
there must compile on both platforms; guard with `#if canImport(AppKit)`.

DEBUG env hooks, passed as `SIMCTL_CHILD_*` to `xcrun simctl launch`:
`RIPTIDE_TV_SKIP_WIZARD=1`, `RIPTIDE_TV_TAB=<label>`,
`RIPTIDE_TV_WIZARD_STEP=trakt|done`, `RIPTIDE_TV_OPEN=<tmdbID>[:movie|show]`,
`RIPTIDE_TV_DEBUG_URL=<url>`.

The phone-pairing contract lives in `Sources/StreamCore/Pairing/` (tested in
StreamCoreTests). First-run wizard: Pair -> Trakt (skippable) -> Done.

## Licensing constraint

Uses MPVKit's LGPL build as a dynamic framework (`Package.swift`). Do not
switch the dependency to the `MPVKit-GPL` product.

## Design/planning docs

`docs/superpowers/specs/` and `docs/superpowers/plans/` (local only, gitignored)
hold the spec-then-plan documents this codebase was built from (superpowers
brainstorming/writing-plans workflow) — check there for the reasoning behind
a feature before re-deriving it from the diff.
