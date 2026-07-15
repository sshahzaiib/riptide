// Sources/RiptideApp/Downloads/DownloadsView.swift
import SwiftUI
import StreamCore

/// Read-only list of in-flight debrid transfers. v1: no row actions.
struct DownloadsView: View {
    @Environment(DownloadsModel.self) private var downloads

    var body: some View {
        List(downloads.rows) { row in
            TransferRow(row: row)
        }
        .overlay {
            if downloads.rows.isEmpty {
                ContentUnavailableView("No active downloads",
                                       systemImage: "arrow.down.circle",
                                       description: Text("Torrents downloading on your debrid services appear here."))
            }
        }
        .safeAreaInset(edge: .bottom) {
            if downloads.pollFailed, let updated = downloads.lastUpdated {
                Text("Last updated \(updated, style: .relative) ago — retrying")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(6).background(.bar)
            }
        }
        .onAppear { downloads.isVisible = true }
        .onDisappear { downloads.isVisible = false }
    }
}

private struct TransferRow: View {
    let row: DownloadsModel.Row

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(row.transfer.filename.isEmpty ? row.transfer.id : row.transfer.filename)
                    .lineLimit(1).truncationMode(.middle)
                Text(row.serviceID.rawValue.uppercased())
                    .font(.caption2.bold())
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                Spacer()
                if row.transfer.bytes > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: row.transfer.bytes,
                                                   countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            switch row.transfer.status {
            case .processing(let progress):
                ProgressView(value: progress, total: 100).controlSize(.small)
                HStack(spacing: 12) {
                    Text("\(Int(progress))%")
                    if let speed = row.transfer.speedBps {
                        Text("\(ByteCountFormatter.string(fromByteCount: speed, countStyle: .file))/s")
                    }
                    if let seeders = row.transfer.seeders {
                        Text("\(seeders) seeders")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            case .failed(let reason):
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
            case .ready:
                EmptyView()   // ready rows are filtered out upstream
            }
        }
        .padding(.vertical, 4)
    }
}
