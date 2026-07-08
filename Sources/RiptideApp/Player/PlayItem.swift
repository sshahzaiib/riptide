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
    let tmdbID: Int?               // TMDB match (movie or show) — nil if unmatched
    let autoResume: Bool           // explicit resume intent: skip the prompt
}
