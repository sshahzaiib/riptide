import SwiftUI
import StreamCore

@main
struct Riptide: App {
    var body: some Scene {
        WindowGroup {
            Text("Riptide — StreamCore \(StreamCore.version)")
                .frame(minWidth: 500, minHeight: 350)
        }
    }
}
