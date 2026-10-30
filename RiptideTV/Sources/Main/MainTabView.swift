import SwiftUI
import StreamCore

struct MainTabView: View {
    @State private var selection: String = {
        #if DEBUG
        if let t = ProcessInfo.processInfo.environment["RIPTIDE_TV_TAB"] { return t }
        #endif
        return "Continue"
    }()

    var body: some View {
        #if DEBUG
        if let open = ProcessInfo.processInfo.environment["RIPTIDE_TV_OPEN"] { debugOpen(open) } else { tabs }
        #else
        tabs
        #endif
    }

    #if DEBUG
    /// RIPTIDE_TV_OPEN=<tmdbID>[:movie|show][:versions]
    private func debugOpen(_ spec: String) -> some View {
        let p = spec.split(separator: ":").map(String.init)
        let id = Int(p[0]) ?? 0
        let media: SearchMedia = p.contains("show")
            ? .show(TMDBShow(id: id, name: "", overview: "", posterPath: nil, firstAirDate: nil, voteAverage: 0))
            : .movie(TMDBMovie(id: id, title: "", overview: "", posterPath: nil, releaseDate: nil, voteAverage: 0))
        return NavigationStack { TitlePage(ref: .media(media), openVersionsOnLoad: p.contains("versions")) }
    }
    #endif

    private var tabs: some View {
        TabView(selection: $selection) {
            SearchTab().tabItem { Text("Search") }.tag("Search")
            ContinueTab(library: AppModels.library).titleStack().tabItem { Text("Continue") }.tag("Continue")
            WatchlistTab().titleStack().tabItem { Text("Watchlist") }.tag("Watchlist")
            ExploreTab().titleStack().tabItem { Text("Explore") }.tag("Explore")
            ShowsTab(library: AppModels.library).titleStack().tabItem { Text("TV Shows") }.tag("TV Shows")
            MoviesTab(library: AppModels.library).titleStack().tabItem { Text("Movies") }.tag("Movies")
            Text("Settings").tabItem { Text("Settings") }.tag("Settings")
        }
    }
}
