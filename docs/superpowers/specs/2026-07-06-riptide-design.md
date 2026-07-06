# Riptide — Real-Debrid Streaming App for macOS

**Date:** 2026-07-06
**Status:** Approved design, pre-implementation
**Working name:** Riptide (rename at will)

## Purpose

A native macOS app that turns a Real-Debrid account into a Netflix-style
streaming library with a full in-app player. Personal Infuse replacement:
browse RD torrents as a poster library, click, stream — no downloading,
no external player.

## Decisions (locked during brainstorming)

| Decision | Choice |
|---|---|
| Playback engine | Embedded libmpv via MPVKit (SPM, LGPL target) — full in-app player |
| Home | New standalone app; Cascade untouched, its RD client copied in |
| Library | TMDB metadata + posters, TV grouped by show/season |
| v1 playback features | Resume positions, embedded subtitle tracks, embedded audio track switching, OpenSubtitles search |
| Platform | macOS only (min 14.0; MPVKit needs ≥11) |

## Architecture

Two SPM targets, mirroring Cascade's proven layout:

```
riptide/
  Package.swift
  Sources/
    StreamCore/          # pure logic, zero UI imports, fully unit-testable
      RealDebrid/        # copied from Cascade DownloadCore + 2 new endpoints
      Parse/             # release-name parser (title/year/S/E/quality)
      TMDB/              # metadata + poster client
      OpenSubtitles/     # subtitle search client
      Store/             # SwiftData: library cache + watch positions
    RiptideApp/          # SwiftUI app target
      Library/           # shelves, detail pages
      Player/            # MPVKit NSViewRepresentable + controls overlay
  Tests/
    StreamCoreTests/
```

### StreamCore components

**RealDebridClient** — lifted from Cascade's
`Sources/DownloadCore/RealDebrid/` (167 + 85 + 33 lines: client, models,
errors). Already provides `accountInfo`, `unrestrictLink`, `addMagnet`,
`selectFiles`, `torrentInfo`, `resolveMagnet`, retry-after handling.
Add two endpoints:
- `GET /torrents` (paginated) → list of user's torrents with filenames,
  sizes, link IDs
- `GET /downloads` (paginated) → previously unrestricted links

**ReleaseNameParser** — pure function: scene name in, structured guess out
(`title, year?, season?, episode?, quality?, source?`). Handles the common
grammar: dots/underscores as spaces, year as title terminator, `S01E02` /
`1x02` patterns, quality tokens (2160p/1080p/720p), source tokens
(BluRay/WEB-DL/WEBRip/HDTV), group suffix after final dash. Fixture-table
tested — this is the highest-test-value component.

**TMDBClient** — search movie/TV by parsed title+year, fetch poster URL,
plot, rating, runtime; fetch episode metadata for parsed S/E. Free API,
requires a one-time API key (user supplies; stored in Keychain alongside
the RD token). Unmatched titles are not an error — see fallback below.

**OpenSubtitlesClient** — search by title/S/E (v1; file-hash matching is a
later refinement), download SRT to a cache directory, hand path to mpv.
Requires free OpenSubtitles API key (Keychain).

**LibraryStore (SwiftData)** — two models:
- `LibraryItem`: RD torrent id, filename, parsed fields, TMDB match
  (id, poster path, plot, rating), media kind (movie/episode), last
  refreshed. Cache so launches after the first render instantly.
- `WatchState`: item id, position seconds, duration, last watched at,
  finished flag. Drives Continue Watching and resume.

### RiptideApp components

**Library UI** — shelves: Continue Watching (from WatchState), Movies,
TV Shows (grouped show → season → episodes). Detail page: poster, plot,
rating, file list (a torrent can hold multiple files), play button.
Search-as-you-filter over the cached library. Unmatched files render as
plain file cards (filename + size + play) — always playable, just no art.

**Player** — MPVKit inside an `NSViewRepresentable`; mpv render API draws
into the view. SwiftUI overlay controls: play/pause, seek bar with
buffered ranges, elapsed/remaining, volume, fullscreen toggle, and one
track-picker component used twice (audio tracks, subtitle tracks — both
read from mpv's `track-list` property). OpenSubtitles button in the
subtitle picker: search → pick → `sub-add` the downloaded file.
Position observer saves to WatchState every 5 s and on close.

## Data flow

1. Launch → load cached library from SwiftData → shelves render immediately.
2. Background refresh: `GET /torrents` → diff against cache → parse new
   filenames → TMDB match → upsert `LibraryItem`s.
3. Play: `unrestrictLink(link)` → direct HTTPS URL → `loadfile` in mpv.
   RD's CDN supports range requests, so seeking works natively.
4. If a `WatchState` exists and isn't finished → resume prompt
   (Resume / Start over).
5. Position autosaved; ≥95 % watched marks finished.

## Error handling

- **RD 401 / token expiry** → sheet prompting for a new API token
  (Keychain-stored, same pattern as Cascade).
- **RD rate limits** → existing retry-after logic in the copied client.
- **Unrestrict fails** (dead link, expired torrent) → alert with the RD
  error message; item stays in library.
- **TMDB no-match or API down** → plain file card fallback; refresh retries
  matching next launch. Never blocks playback.
- **mpv load failure** → surface mpv's error string in the player window.
- **OpenSubtitles down/quota** → picker shows the error inline; embedded
  tracks unaffected.

## Testing

Cascade's pattern: StreamCore is pure and unit-tested; the app shell is
verified by running it.

- **ReleaseNameParser** — fixture table of real-world scene names
  (movies, TV, anime-style, multi-part, garbage). The big suite.
- **RD client additions** — decode fixtures for `/torrents` and
  `/downloads`; pagination.
- **TMDB/OpenSubtitles clients** — request construction + response
  decoding against canned JSON.
- **LibraryStore** — upsert/diff logic, watch-state transitions
  (in-memory SwiftData container).
- **Player/UI** — manual verification; no UI tests in v1.

## Dependencies

- **MPVKit** (SPM, `MPVKit` LGPL binary target) — mpv 0.41 / ffmpeg n8.1,
  actively maintained, macOS ≥11. The only third-party dependency.
- TMDB and OpenSubtitles are plain REST via URLSession — no SDKs.

## Licensing note

MPVKit's LGPL target is used as a dynamic framework — fine for personal
use and even distribution. Do not use the `-GPL` variant unless the app
itself goes GPL.

## Out of scope (v1)

iOS/tvOS, Trakt sync, other debrid services (AllDebrid/Premiumize),
downloading (Cascade's job), file-hash subtitle matching, library sharing,
Chromecast/AirPlay, PiP.

## Open items for planning

- Copy vs. depend: RD client is *copied* from Cascade (285 lines), not a
  shared package — divergence is acceptable, coupling is not.
- TMDB + OpenSubtitles API keys: user creates free accounts once; app
  stores keys in Keychain; settings sheet for entry.
