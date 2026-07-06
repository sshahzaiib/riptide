import SwiftUI

struct MPVPlayerView: NSViewControllerRepresentable {
    let model: PlayerModel
    let url: URL
    let startAt: Double?

    func makeNSViewController(context: Context) -> MPVPlayerController {
        let controller = MPVPlayerController()
        model.attach(controller)
        // Defer load until the view (and mpv) exist.
        DispatchQueue.main.async {
            controller.loadFile(url, startAt: startAt)
        }
        return controller
    }

    func updateNSViewController(_ controller: MPVPlayerController, context: Context) {}
}
