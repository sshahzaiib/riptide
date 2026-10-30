import SwiftUI
import StreamCore

struct RootView: View {
    @AppStorage("wizardDone") private var wizardDone = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if !wizardDone || !AppSettings.shared.isConfigured {
                WizardView(wizardDone: $wizardDone)
            } else {
                Text("Main") // Task 8 replaces with MainTabView
            }
        }
        .task { await pullTrakt() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await pullTrakt() } }
        }
    }

    private func pullTrakt() async {
        guard TraktService.shared.isConnected else { return }
        await TraktService.shared.pullSync(store: AppModels.store)
    }
}
