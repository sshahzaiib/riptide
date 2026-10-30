import SwiftUI
import StreamCore

struct RootView: View {
    @AppStorage("wizardDone") private var wizardDone = false
    @Environment(\.scenePhase) private var scenePhase

    private var forceMain: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["RIPTIDE_TV_SKIP_WIZARD"] == "1"
        #else
        false
        #endif
    }

    var body: some View {
        Group {
            if forceMain || (wizardDone && AppSettings.shared.isConfigured) {
                MainTabView()
            } else {
                WizardView(wizardDone: $wizardDone)
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
