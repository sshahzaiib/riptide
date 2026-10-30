import SwiftUI
import class StreamCore.LibraryItem

struct UpNextBanner: View {
    let next: LibraryItem
    let countdown: Int?
    let onPlay: () -> Void
    let onCancel: () -> Void
    @FocusState private var playFocused: Bool

    private var line: String {
        let name = next.title.isEmpty ? next.filename : next.title
        guard let s = next.season, let e = next.episode else { return name }
        return "\(name) · S\(s) E\(e)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Up next").font(.caption).foregroundStyle(.secondary)
            Text(line).font(.headline).lineLimit(2)
            HStack(spacing: 20) {
                Button(countdown.map { "Playing in \($0)s" } ?? "Play Now", systemImage: "play.fill", action: onPlay)
                    .buttonStyle(.borderedProminent)
                    .focused($playFocused)
                Button("Cancel", action: onCancel)
            }
        }
        .padding(30)
        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 20))
        .padding(60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .onAppear { playFocused = true }
    }
}
