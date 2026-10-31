import Foundation

enum SidebarSection: String, CaseIterable, Identifiable {
    case discover = "Discover"
    case watchlist = "Watchlist"
    case continueWatching = "Continue Watching"
    case history = "History"
    case movies = "Movies"
    case shows = "TV Shows"
    case files = "Other Files"
    case downloads = "Transfers"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .discover: "safari"
        case .watchlist: "bookmark"
        case .continueWatching: "play.circle"
        case .history: "clock.arrow.circlepath"
        case .movies: "film"
        case .shows: "tv"
        case .files: "doc"
        case .downloads: "arrow.left.arrow.right.circle"
        }
    }
}
