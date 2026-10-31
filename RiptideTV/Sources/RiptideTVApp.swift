import SwiftUI
import AVFoundation

@main
struct RiptideTVApp: App {
    init() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .moviePlayback)
        try? s.setActive(true)
    }

    var body: some Scene {
        WindowGroup { RootView() }
    }
}
