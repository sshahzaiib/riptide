# Riptide Plan 4 — Trakt Integration

**Date:** 2026-07-08
**Status:** Approved (user selected all four features: scrobbling, two-way
resume sync, watched-history pull, ratings).

## A. Auth — OAuth device code flow

User creates a Trakt API app (https://trakt.tv/oauth/applications, redirect
URI `urn:ietf:wg:oauth:2.0:oob`) and enters its **Client ID** and **Client
Secret** in Riptide Settings. "Connect Trakt" button:

1. `POST /oauth/device/code` `{client_id}` → `device_code, user_code,
   verification_url, expires_in, interval`.
2. Sheet shows `user_code` + link to `verification_url`.
3. App polls `POST /oauth/device/token` `{code, client_id, client_secret}`
   every `interval` seconds until `expires_in` elapses. HTTP 200 → tokens;
   400 = pending (keep polling); 404/409/410/418 = terminal errors.
4. Tokens (`access_token, refresh_token, created_at, expires_in`) stored in
   Keychain as JSON under account `trakt-tokens` (service
   `com.northlab.riptide`). Client ID/secret under `trakt-client-id` /
   `trakt-client-secret`.

Authorized requests carry `Authorization: Bearer`, `trakt-api-version: 2`,
`trakt-api-key: <client-id>`, `Content-Type: application/json`. On 401 the
client refreshes once (`POST /oauth/token`, `grant_type=refresh_token`),
persists via an `onTokensRefreshed` callback, and retries the request. A
failed refresh surfaces as `TraktError.unauthorized` → Settings shows
"Reconnect Trakt".

## B. Identity mapping

`TraktMedia` enum built from LibraryItem:
- `mediaKind == "movie"` → `movie(tmdbID:)` → payload `{"movie":{"ids":{"tmdb":N}}}`
- `mediaKind == "episode"` → `episode(showTMDBID:, season:, episode:)` →
  payload `{"show":{"ids":{"tmdb":N}},"episode":{"season":S,"number":E}}`

Items with `tmdbID == nil` are invisible to all Trakt features.

## C. Scrobbling (PlayerModel hooks)

- playback starts / unpauses → `POST /scrobble/start`
- pause → `POST /scrobble/pause` (this is also the resume-position push:
  Trakt playback progress is fed by pause/stop events)
- window closes or file ends → `POST /scrobble/stop`
Payload: media JSON + `progress` (percent = position/duration×100). Trakt
marks watched at ≥80% on stop. All calls fire-and-forget `Task`s; failures
log and are dropped. No scrobble when duration ≤ 0 or item unmatched.

## D. Pull sync (after each library refresh)

`TraktSyncer` (StreamCore, injectable client + store, unit-tested):
1. `GET /sync/playback` → in-progress positions (percent + `paused_at`).
   Merge rule: apply when `paused_at` > local `lastWatchedAt` AND local
   `durationSeconds > 0` (percent→seconds needs a known duration; items
   never played locally sync after their first local play). Sets position,
   `finished=false`, `lastWatchedAt=paused_at`.
2. `GET /sync/watched/movies` + `GET /sync/watched/shows` → watched history.
   Merge rule: apply when `last_watched_at` > local `lastWatchedAt` (or no
   local state). Marks `finished=true`, keeps local position/duration.
Local WatchState stays source of truth when newer. Sync errors log + skip.

## E. Ratings

Show page hero rates the SHOW; movie page rates the movie (episode-level
rating out of v1). Star row (1–10) beside the TMDB badge: shows the user's
Trakt rating, tap to `POST /sync/ratings`. Current ratings loaded on page
open via `GET /sync/ratings/shows` / `/movies` filtered by tmdb id.

## F. App plumbing

- `TraktService` (@MainActor singleton, RiptideApp): owns TraktClient built
  from Keychain credentials, persists refreshed tokens, exposes
  `isConnected`, scrobble/rate/pull wrappers. Nil-safe when not configured.
- SettingsView: Client ID + Secret fields, Connect/Disconnect button, device
  code sheet, "Reconnect" state on auth failure.
- LibraryModel.refresh(): after RD/TMDB refresh, `await TraktService.shared.pullSync(store:)`.
- PlayItem gains `tmdbID: Int?` so the player can scrobble.

## G. Testing

StreamCore TDD via MockURLProtocol (serial `swift test`): device-code flow
(pending→success), token refresh on 401, scrobble payload construction,
playback/watched decode fixtures, TraktSyncer merge rules (newer-wins both
directions) on in-memory store. App target: `swift build` + manual E2E.

## Out of scope

Episode-level ratings, Trakt lists/collections, checkin API, removing
Trakt playback entries, VIP features, comments.
