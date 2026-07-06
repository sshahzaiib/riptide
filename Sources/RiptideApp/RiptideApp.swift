import SwiftUI
import StreamCore

@main
struct Riptide: App {
    private let store: LibraryStore

    init() {
        do { store = try LibraryStore.onDisk() }
        catch { fatalError("Failed to open library store: \(error)") }
    }

    var body: some Scene {
        WindowGroup {
            LibraryRootView(store: store)
                .frame(minWidth: 900, minHeight: 600)
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
