import SwiftUI

struct TraktSection: View {
    private let trakt = TraktService.shared
    @State private var confirmSignOut = false
    @State private var path = false

    var body: some View {
        Section("Trakt") {
            if !trakt.isConfigured {
                Text("Add Trakt app credentials from Set up from another device")
                    .foregroundStyle(.secondary)
            } else if !trakt.isConnected {
                Button("Sign in to Trakt") { path = true }
                    .navigationDestination(isPresented: $path) {
                        TraktSignInView(onDone: {
                            path = false
                            Task { await trakt.pullSync(store: AppModels.store) }
                        })
                    }
            } else {
                Button("Sign out of Trakt", role: .destructive) { confirmSignOut = true }
                    .confirmationDialog("Sign out of Trakt?", isPresented: $confirmSignOut) {
                        Button("Sign out", role: .destructive) { trakt.disconnect() }
                    }
            }
        }
    }
}
