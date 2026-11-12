import SwiftUI

struct ServicesSection: View {
    let settings: AppSettings

    var body: some View {
        Section {
            row("Real-Debrid", settings.rdToken)
            row("AllDebrid", settings.adToken)
            row("TMDB", settings.tmdbToken)
            row("OpenSubtitles", settings.openSubsKey)
        } header: {
            Text("Services")
        } footer: {
            Text("Select a service to change its key from another device")
        }
    }

    /// Rows are links (to where keys are changed), not plain text: tvOS only
    /// scrolls to what can take focus, so static rows at the top of the list
    /// could not be scrolled back into view.
    private func row(_ name: String, _ value: String) -> some View {
        NavigationLink { PairingDestination() } label: {
            LabeledContent(name, value: value.isEmpty ? "Not set" : "Set")
        }
    }
}
