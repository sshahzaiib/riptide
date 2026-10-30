import Foundation
import StreamCore

/// What the stream picker needs to query addons for one movie or episode.
struct StreamRequest: Identifiable {
    let id = UUID()
    let type: StremioAddonClient.MediaType
    let imdbID: String
    let title: String
    let season: Int?
    let episode: Int?
    let tmdbID: Int
}
