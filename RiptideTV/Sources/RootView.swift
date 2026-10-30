import SwiftUI
import StreamCore

struct RootView: View {
    @State private var server = PairingServer.live()

    var body: some View {
        PairingScreen(server: server, onContinue: {})
    }
}
