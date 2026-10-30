import SwiftUI
import StreamCore

struct RootView: View {
    // Temporary (Task 5): stub apply; final routing arrives in Task 7.
    @State private var server = PairingServer(apply: { payload in
        let values: [(String, String, String?)] = [
            ("rdToken", "Real-Debrid token", payload.rdToken),
            ("adToken", "AllDebrid token", payload.adToken),
            ("tmdbToken", "TMDB token", payload.tmdbToken),
            ("traktClientID", "Trakt client ID", payload.traktClientID),
            ("traktClientSecret", "Trakt client secret", payload.traktClientSecret),
            ("openSubsKey", "OpenSubtitles key", payload.openSubsKey),
            ("addonURLs", "Addon URLs", payload.addonURLs.first),
        ]
        return values.map { PairingFieldState(name: $0.0, label: $0.1, isSet: !($0.2 ?? "").isEmpty, result: "stub") }
    })

    var body: some View {
        PairingScreen(server: server, onContinue: {})
    }
}
