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

    #if DEBUG
    private let debugItem: PlayItem? = ProcessInfo.processInfo.environment["RIPTIDE_TV_DEBUG_URL"]
        .flatMap(URL.init(string:)).map {
            PlayItem(itemKey: "debug", title: "Debug", url: $0, resumeFrom: nil, subtitleQuery: "",
                     season: nil, episode: nil, tmdbID: nil, autoResume: false)
        }
    #endif

    var body: some View {
        Group {
            #if DEBUG
            if let debugItem { PlayerScreen(item: debugItem) } else { content }
            #else
            content
            #endif
        }
        .task { await pullTrakt() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await pullTrakt() } }
        }
    }

    @ViewBuilder private var content: some View {
        Group {
            if forceMain || (wizardDone && AppSettings.shared.isConfigured) {
                MainTabView()
            } else {
                WizardView(wizardDone: $wizardDone)
            }
        }
    }

    private func pullTrakt() async {
        guard TraktService.shared.isConnected else { return }
        await TraktService.shared.pullSync(store: AppModels.store)
    }
}
