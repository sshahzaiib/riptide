import AppKit
import SwiftUI
import StreamCore

// Temporary diagnostics: RIPTIDE_DEBUG_URL=<video url> opens a player window on launch.
private struct DebugAutoplay: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    func body(content: Content) -> some View {
        content.task {
            guard let raw = ProcessInfo.processInfo.environment["RIPTIDE_DEBUG_URL"],
                  let url = URL(string: raw) else { return }
            openWindow(value: PlayItem(itemKey: "debug#0", title: "Debug", url: url,
                                       resumeFrom: nil, subtitleQuery: "debug",
                                       season: 1, episode: 1, tmdbID: nil, autoResume: false))
        }
    }
}

@main
struct Riptide: App {
    private let store: LibraryStore

    init() {
        do { store = try LibraryStore.onDisk() }
        catch { fatalError("Failed to open library store: \(error)") }
        // Unbundled executable (swift run): without .regular activation the
        // system treats the process as background and denies Spaces fullscreen.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup {
            LibraryRootView(store: store)
                .frame(minWidth: 900, minHeight: 600)
                .modifier(DebugAutoplay())
        }

        WindowGroup(for: PlayItem.self) { $item in
            if let item {
                PlayerWindowView(item: item, store: store)
                    .frame(minWidth: 800, minHeight: 450)
            }
        }
        .windowStyle(.hiddenTitleBar)
    }
}
