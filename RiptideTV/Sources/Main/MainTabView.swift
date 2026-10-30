import SwiftUI

struct MainTabView: View {
    @State private var selection: String = {
        #if DEBUG
        if let t = ProcessInfo.processInfo.environment["RIPTIDE_TV_TAB"] { return t }
        #endif
        return "Continue"
    }()

    var body: some View {
        TabView(selection: $selection) {
            SearchTab().tabItem { Text("Search") }.tag("Search")
            ContinueTab(library: AppModels.library).tabItem { Text("Continue") }.tag("Continue")
            WatchlistTab().tabItem { Text("Watchlist") }.tag("Watchlist")
            ExploreTab().tabItem { Text("Explore") }.tag("Explore")
            ShowsTab(library: AppModels.library).tabItem { Text("TV Shows") }.tag("TV Shows")
            MoviesTab(library: AppModels.library).tabItem { Text("Movies") }.tag("Movies")
            Text("Settings").tabItem { Text("Settings") }.tag("Settings")
        }
    }
}
