import SwiftUI

/// Toolbar button that opens the downloads popover, with an active-badge glyph.
/// Reads `LocalDownloadManager` from the environment so it can live in any
/// toolbar (library root + detail pages).
struct DownloadsToolbarButton: View {
    @Environment(LocalDownloadManager.self) private var downloads
    @State private var showPopover = false

    var body: some View {
        Button { showPopover.toggle() } label: {
            Image(systemName: downloads.activeCount > 0
                  ? "arrow.down.circle.fill" : "arrow.down.circle")
        }
        .help("Downloads")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            LocalDownloadsPopover().environment(downloads)
        }
    }
}
