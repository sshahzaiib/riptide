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
            Text("Change keys from Set up from another device")
        }
    }

    private func row(_ name: String, _ value: String) -> some View {
        LabeledContent(name, value: value.isEmpty ? "Not set" : "Set")
    }
}
