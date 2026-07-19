import SwiftUI
import StreamCore
import DownloadKit

struct LocalDownloadsPopover: View {
    @Environment(LocalDownloadManager.self) private var downloads
    @State private var pendingDelete: DownloadRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Downloads").font(.headline).padding(12)
            Divider()
            let active = downloads.active.keys.sorted()
            let completed = downloads.completedRecords()
            if active.isEmpty && completed.isEmpty {
                Text("No downloads")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(24)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(active, id: \.self) { key in
                            if let p = downloads.progress(key) { activeRow(key: key, progress: p) }
                        }
                        ForEach(completed, id: \.itemKey) { rec in completedRow(rec) }
                    }
                    .padding(12)
                }
                .frame(maxHeight: 360)
                if !completed.isEmpty {
                    Divider()
                    Text(storageLine(completed))
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                }
            }
        }
        .frame(width: 340)
        .confirmationDialog("Delete this download from disk?",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { rec in
            Button("Delete from Disk", role: .destructive) {
                downloads.deleteLocal(itemKey: rec.itemKey)
            }
        } message: { rec in
            Text(downloads.displayTitle(rec.itemKey))
        }
    }

    private func storageLine(_ completed: [DownloadRecord]) -> String {
        let total = completed.reduce(Int64(0)) { $0 + $1.totalBytes }
        let size = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        let n = completed.count
        return "\(n) download\(n == 1 ? "" : "s") · \(size) on disk"
    }

    @ViewBuilder
    private func activeRow(key: String, progress p: DownloadProgress) -> some View {
        let fraction = p.totalBytes.map { Double(p.bytesDownloaded) / Double(max($0, 1)) }
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(downloads.displayTitle(key)).font(.callout).lineLimit(1)
                Spacer()
                Button { downloads.cancel(itemKey: key) } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            ProgressView(value: fraction ?? 0)
            Text(speedLine(p)).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func completedRow(_ rec: DownloadRecord) -> some View {
        HStack {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(downloads.displayTitle(rec.itemKey)).font(.callout).lineLimit(1)
            Spacer()
            Button("Reveal") { downloads.reveal(itemKey: rec.itemKey) }
                .buttonStyle(.link).font(.caption)
            Button { pendingDelete = rec } label: {
                Image(systemName: "trash").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).help("Delete from disk")
        }
    }

    private func speedLine(_ p: DownloadProgress) -> String {
        let mb = { (b: Int64) in String(format: "%.0f MB", Double(b) / 1_048_576) }
        let speed = String(format: "%.1f MB/s", p.bytesPerSecond / 1_048_576)
        if let total = p.totalBytes {
            return "\(mb(p.bytesDownloaded)) / \(mb(total)) · \(speed)"
        }
        return "\(mb(p.bytesDownloaded)) · \(speed)"
    }
}
