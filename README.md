# Riptide

Native macOS app that streams your Real-Debrid library with an embedded
mpv player (MKV, every codec) — a personal Infuse replacement.

Browse your debrid torrents as a poster library, match them against TMDB
metadata, play anything mpv can decode, and sync watch progress with Trakt.

## Requirements

- macOS 14+
- Real-Debrid premium account + [API token](https://real-debrid.com/apitoken)
- Free [TMDB API Read Access Token](https://www.themoviedb.org/settings/api) (posters/metadata)
- Optional: [AllDebrid API key](https://alldebrid.com/apikeys) as a backup resolver
- Optional: free [OpenSubtitles API key](https://www.opensubtitles.com/en/consumers)
- Optional: a [Trakt API app](https://trakt.tv/oauth/applications) for watch-history sync

Every key is entered in Settings and stored only in the macOS Keychain.

## Install

Download the latest signed and notarized `.dmg` from
[Releases](https://github.com/sshahzaiib/riptide/releases), drag Riptide
to Applications, and launch. First launch opens Settings — paste your keys,
hit refresh, and your library appears as posters. Click to stream.

## Build from source

    swift build          # StreamCore + RiptideApp
    swift test           # StreamCore unit tests
    scripts/run.sh       # build, sign with a stable dev identity, launch

Use `scripts/run.sh` rather than `swift run RiptideApp`: an ad-hoc signed
binary changes its signature every rebuild, so macOS re-prompts for Keychain
access each launch.

## What Riptide is and is not

Riptide is a player for files that already sit in **your own** debrid
account. It hosts nothing, indexes nothing, and ships with no content
sources. You are responsible for what you add to your account and for
complying with the terms of the services you connect.

## Attribution

- This product uses the TMDB API but is not endorsed or certified by TMDB.
- Riptide uses Trakt but is not endorsed or certified by Trakt.
- Subtitles via [OpenSubtitles](https://www.opensubtitles.com).
- Playback via [mpv](https://mpv.io) through
  [MPVKit](https://github.com/mpvkit/MPVKit) (LGPL build, dynamically
  linked). Do not switch the dependency to the `MPVKit-GPL` product.

## License

[GPL-3.0](LICENSE). Copyright © 2026 Shahzaib Muhammad Akram.
