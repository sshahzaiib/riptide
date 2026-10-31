import SwiftUI
import StreamCore

struct WizardView: View {
    enum Step { case pair, trakt, done }

    @Binding var wizardDone: Bool
    @State private var step: Step = .pair
    @State private var server = PairingServer.live()

    init(wizardDone: Binding<Bool>) {
        _wizardDone = wizardDone
        #if DEBUG
        switch ProcessInfo.processInfo.environment["RIPTIDE_TV_WIZARD_STEP"] {
        case "trakt": _step = State(initialValue: .trakt)
        case "done": _step = State(initialValue: .done)
        default: break
        }
        #endif
    }

    var body: some View {
        switch step {
        case .pair:
            PairingScreen(server: server, onContinue: {
                step = TraktService.shared.isConfigured ? .trakt : .done
            })
        case .trakt:
            TraktSignInView(onDone: { step = .done })
        case .done:
            VStack(spacing: 32) {
                Text("You're all set").font(.largeTitle.bold())
                Text(summary).font(.title3).foregroundStyle(.secondary)
                Button("Start") { wizardDone = true }
            }
        }
    }

    private var summary: String {
        var parts = ["Real-Debrid", "TMDB"]
        if TraktService.shared.isConnected { parts.append("Trakt") }
        return parts.joined(separator: " · ")
    }
}
