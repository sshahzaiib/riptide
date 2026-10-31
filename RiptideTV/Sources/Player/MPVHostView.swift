import SwiftUI

/// Hosts the single MPVPlayerController. Episode changes go through
/// `PlayerModel.advance(to:)`, which reloads on this same controller.
struct MPVHostView: UIViewControllerRepresentable {
    let model: PlayerModel
    let item: PlayItem
    let startAt: Double?

    func makeUIViewController(context: Context) -> MPVPlayerController {
        let controller = MPVPlayerController()
        controller.loadViewIfNeeded()   // viewDidLoad creates mpv; loadFile needs it
        model.attach(controller)
        controller.loadFile(item.url, startAt: startAt)
        return controller
    }

    func updateUIViewController(_ controller: MPVPlayerController, context: Context) {}
}
