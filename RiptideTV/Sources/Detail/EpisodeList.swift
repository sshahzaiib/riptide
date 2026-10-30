import SwiftUI
import class StreamCore.LibraryItem

struct EpisodeRow: Identifiable {
    let id: String
    let season: Int
    let number: Int
    let name: String
    let items: [LibraryItem]          // owned files, preference-ranked; empty = not in library
    var progress: Double?
    var finished = false
}

struct EpisodeList: View {
    let rows: [EpisodeRow]
    let onPlay: (EpisodeRow) -> Void

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(rows) { row in
                Button { onPlay(row) } label: {
                    HStack(spacing: 20) {
                        Text(row.number > 0 ? "E\(row.number) · \(row.name)" : row.name).lineLimit(1)
                        Spacer()
                        if row.finished {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else if let p = row.progress, p > 0 {
                            ProgressView(value: min(p, 1)).frame(width: 140)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }
}
