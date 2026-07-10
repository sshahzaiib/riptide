# Add Magnets / Torrent Files From the App — Design

**Issue:** #6 · **Date:** 2026-07-10 · **Status:** approved

## Goal

Paste a magnet link or drop a `.torrent` file into Riptide and have it land in
Real-Debrid — and the library — without opening real-debrid.com. Cached content
is reachable immediately; uncached content shows a confirmation and appears
once RD finishes (progress UI is out of scope, tracked in #12).

## What already exists

`RealDebridClient` (StreamCore) already has `addMagnet`, `selectFiles`,
`torrentInfo`, `listTorrents`/`allTorrents`, and error mapping. The library
pipeline (LibraryRefresher → per-file expansion → TMDB matching) handles new
torrents with no changes.

## New pieces

### StreamCore

1. **`RealDebridClient.addTorrentFile(_ data: Data) async throws -> AddMagnetResult`**
   — `PUT /torrents/addTorrent` with the raw `.torrent` bytes as the body
   (`Content-Type: application/x-bittorrent`). Same response shape as
   `addMagnet`.

2. **`TorrentAdder`** — orchestration type, testable via `MockURLProtocol`
   (same pattern as `TraktSyncer`). One public entry:

   ```swift
   enum Outcome: Equatable {
       case alreadyInLibrary(torrentID: String)
       case ready(torrentID: String)        // RD status "downloaded"
       case downloading(torrentID: String)  // anything else (queued/downloading/…)
   }

   enum AddSource { case magnet(String); case file(Data) }

   struct Added {
       let outcome: Outcome
       let torrentID: String
       let files: [TorrentFile]         // all files RD listed — for "Edit files…"
       let selectedFileIDs: [Int]
   }

   func add(magnet: String) async throws -> Added
   func add(torrentFile: Data) async throws -> Added
   func reselect(source: AddSource, torrentID: String, fileIDs: [Int]) async throws -> Added
   ```

   **`reselect` is delete + re-add:** RD rejects `selectFiles` on a torrent
   whose files are already selected (`action_already_done`), so editing the
   selection means `DELETE /torrents/delete/{id}`, re-adding from the
   original source, and selecting the chosen ids (file ids are stable —
   they're 1-indexed positions in the same torrent). Needs a new
   `deleteTorrent(id)` client endpoint.

   Flow for `add`:
   - **Dedupe:** extract the infohash from the magnet's `xt=urn:btih:` param
     (*simplification:* `.torrent` files skip pre-add dedupe — RD dedupes
     server-side and hashing the bencoded info dict isn't worth it). Compare
     lowercased against `allTorrents()` hashes → `.alreadyInLibrary`.
     Requires adding the `hash` field to `TorrentListItem` (RD returns it;
     we don't decode it today).
   - `addMagnet` / `addTorrentFile` → torrent id.
   - `torrentInfo(id)` → wait (short poll, reuse `pollUntil`) until RD lists
     files (`waiting_files_selection`).
   - **Auto-select video files only:** filter `files` by the video-extension
     whitelist in `ReleaseNameParser` (mkv, mp4, avi, m4v, mov, wmv, ts,
     webm, flv, mpg, mpeg — expose it as a reusable constant); exclude paths
     containing `sample` (case-insensitive). If the filter yields nothing,
     select all (better than a stuck torrent).
   - `selectFiles(id, ids)` → one `torrentInfo` re-check → map RD status to
     `AddOutcome`.

### App (RiptideApp)

3. **`TorrentAddModel`** (@MainActor @Observable) — thin wrapper: sheet state
   (`idle / adding / done(AddedTorrent) / error(String)`), triggers
   `LibraryRefresher` on success, exposes the target item key for
   post-add navigation when outcome is `.ready` / `.alreadyInLibrary`.

4. **`AddTorrentSheet`** — single sheet all entry points funnel into:
   - Text field for magnet (pre-filled from `NSPasteboard` when it holds a
     `magnet:` string) + "Choose .torrent…" (`fileImporter`).
   - Pre-filled + auto-submit when opened via drop / ⌘V / magnet URL.
   - Progress while adding; on success a summary row ("Selected 8 video
     files") with **Edit files…** → checklist sheet (pre-checked to current
     selection) → `reselect`. Auto-dismiss after a beat when no edit.
   - Errors inline in the sheet.

5. **Entry points**
   - Library toolbar **+** button → empty sheet.
   - `.dropDestination` on the library root: `.torrent` file URLs and dragged
     magnet text.
   - **⌘V**: Edit ▸ Paste menu command in the library window — if the
     pasteboard holds a magnet, open the sheet auto-submitted.
   - **magnet: URL handler**: `onOpenURL` + `CFBundleURLTypes` declaration.
     *Caveat:* LaunchServices only registers schemes for `.app` bundles — this
     activates when the app is packaged; the unbundled `run.sh` debug binary
     won't receive magnet clicks. The other three entry points work today.

6. **Post-add behavior** — library refresh always; if `.ready` or
   `.alreadyInLibrary`, navigate to/select the item in the sidebar; if
   `.downloading`, toast "Added — downloading on Real-Debrid".

## Error handling

- RD errors already map via `RealDebridError` — show `localizedDescription`
  in the sheet.
- Invalid input (not a magnet / unreadable file): inline validation before
  any network call.
- Poll timeout waiting for file list: surface as an error with the torrent id
  (it still exists on RD; next library refresh may pick it up).

## Testing

StreamCore XCTests (MockURLProtocol):
- `addTorrentFile` sends PUT with raw body + correct content type.
- Video-only selection: mixed pack (episodes + sample.mkv + nfo) selects only
  real videos; all-junk pack falls back to select-all.
- Dedupe: magnet whose infohash matches an existing torrent →
  `.alreadyInLibrary`, no add call made.
- Outcome mapping: `downloaded` → `.ready`, `queued` → `.downloading`.
- `reselect` deletes the torrent, re-adds from source, selects the given ids.
- `deleteTorrent` sends DELETE to `torrents/delete/{id}`.

UI layer stays thin (no UI tests).

## Out of scope

Uncached download progress/notifications (#12), streaming from arbitrary
hoster links (#20), auto-play after add.
