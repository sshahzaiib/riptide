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
