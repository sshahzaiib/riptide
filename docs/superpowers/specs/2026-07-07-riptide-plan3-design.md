# Riptide Plan 3 — Infuse-Style Pages + Full Player Experience

**Date:** 2026-07-07
**Status:** Approved (user confirmed scope: core show page + cast & crew + ratings
badges + movie hero treatment + skip intro; plus player fixes and "full video
player experience with keyboard shortcuts").

## A. TMDB enrichment (StreamCore, lazy — no schema change)

Rich data is fetched when a page opens, never stored in SwiftData. URLCache
provides revisit speed; offline degrades to the current filename-based UI.

New TMDBClient endpoints (all TDD):
- `showDetails(id) -> TMDBShowDetails` — `GET /tv/{id}`: backdropPath, overview,
  voteAverage, firstAirDate, name.
- `seasonEpisodes(showID:season:) -> [TMDBSeasonEpisode]` — `GET /tv/{id}/season/{n}`:
  per episode: episodeNumber, name, overview, stillPath, airDate, runtime.
- `showCredits(id)` / `movieCredits(id) -> [TMDBCastMember]` — `GET /tv|movie/{id}/credits`:
  top-billed cast (name, character, profilePath), capped at first 12.
- `movieDetails(id) -> TMDBMovieDetails` — `GET /movie/{id}`: backdropPath,
  runtime, overview, voteAverage, releaseDate, title.

Image widths: backdrop w1280, episode still w300, cast profile w185 (existing
`TMDB.imageURL(path:width:)`).

## B. Show page (replaces ShowDetailView)

- **Hero**: full-width backdrop with bottom-up dark gradient; over it: show
  title, year, TMDB score badge (existing stored rating), and the SELECTED
  episode's info: "S1 · E5 — The Wolf and the Lion", air date, runtime,
  3-line overview.
- **Resume pill**: "Resume S1E5 · 24:11" targeting the most-recently-watched
  unfinished episode of the show (from WatchState); "Play S1E1" when nothing
  started. Clicking plays immediately (resume position passed through the
  existing prompt-free path since the intent is explicit).
- **Season strips**: one horizontal ScrollView per season; episode cards
  (still image 200×112, caption "5. The Wolf and the Lion"); orange progress
  bar on partially-watched cards; checkmark badge on finished ones; cards
  without stills show a number placeholder. Click selects (updates hero
  panel); the hero Play button plays the selection.
- **Cast & Crew row**: horizontal strip of circular profile photos, name +
  character, from showCredits.
- TMDB episode metadata is merged with local LibraryItems by (season,
  episode); local files with no TMDB counterpart still render with filename.

## C. Movie page (replaces ItemDetailView layout for matched movies)

Backdrop hero + gradient, title, year/quality/runtime/TMDB badge, overview,
cast row (movieCredits), Resume pill with timestamp when a WatchState exists
("Resume · 24:11") else "Play". Unmatched items keep the current plain layout.

## D. Player fixes + full experience

Fixes:
- **Resize bug**: video layer only resizes in `viewDidLayout`, which SwiftUI's
  layer-hosting view doesn't reliably trigger. Fix: custom `NSView` subclass
  owning the MetalLayer, overriding `layout()` and
  `viewDidChangeBackingProperties()` to keep layer frame + drawableSize synced
  with bounds and screen scale.
- **Fullscreen**: use `controller.view.window?.toggleFullScreen(nil)` (not
  `NSApp.keyWindow`).

New:
- **Keyboard shortcuts** (NSEvent local monitor scoped to the player window):
  Space play/pause, ←/→ seek ∓10s, ↑/↓ volume ±5, F fullscreen, M mute,
  S skip intro. (Esc exits fullscreen natively.)
- **Auto-hide**: controls + cursor hide after 3s without mouse movement while
  playing; reappear on movement; always visible while paused.
- **Playback speed** menu: 0.5 / 0.75 / 1 / 1.25 / 1.5 / 2 (mpv `speed`).
- **Mute** toggle button + M key (mpv `mute`).
- **Skip Intro**: button visible during the first 6 minutes of episodes
  (PlayItem.season != nil): jumps to the next mpv chapter when the file has
  chapters, else +90s.
- **Double-click** video toggles fullscreen.

## E. Error handling

Every TMDB fetch is best-effort and independent: missing backdrop → blurred
poster fallback; failed season fetch → filename cards; failed credits → row
hidden. No fetch failure ever blocks playback.

## F. Testing

- StreamCore: new endpoint request construction + decode fixtures (TDD, MockURLProtocol).
- App target: `swift build` per task + manual E2E (resize, fullscreen, every
  shortcut, skip intro on a GoT episode, show page with 5 seasons, movie hero).

## Out of scope

Trakt, chapter-name-based intro detection, thumbnail scrubbing previews,
picture-in-picture, Touch Bar.
