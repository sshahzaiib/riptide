import SwiftUI

struct MainTabView: View {
    @State private var selection = "Continue"

    var body: some View {
        TabView(selection: $selection) {
            Text("Search").tabItem { Text("Search") }.tag("Search")
            Text("Continue").tabItem { Text("Continue") }.tag("Continue")
            Text("Watchlist").tabItem { Text("Watchlist") }.tag("Watchlist")
            Text("Explore").tabItem { Text("Explore") }.tag("Explore")
            ShowsTab(library: AppModels.library).tabItem { Text("TV Shows") }.tag("TV Shows")
            MoviesTab(library: AppModels.library).tabItem { Text("Movies") }.tag("Movies")
            Text("Settings").tabItem { Text("Settings") }.tag("Settings")
        }
    }
}
