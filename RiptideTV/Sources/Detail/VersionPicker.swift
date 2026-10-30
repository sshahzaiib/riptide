import SwiftUI
import StreamCore
import class StreamCore.LibraryItem

/// Library versions first, then addon streams. Picking resolves to a PlayItem.
struct VersionPicker: View {
    let libraryItems: [LibraryItem]
    let request: StreamRequest?
    let onPick: (PlayItem) -> Void
    @State private var model = StreamPickerModel()
    @State private var status: String?
    @State private var picking = false

    var body: some View {
        VStack(alignment: .leading) {
            if let status {
                HStack {
                    if picking { ProgressView() }
                    Text(model.downloadProgress.map { "\(status) \(Int($0))%" } ?? status)
                }.padding(.horizontal, 40)
            }
            List {
                ForEach(libraryItems, id: \.itemKey) { item in
                    Button { pick { try await PlayItemBuilder.make(for: item, store: AppModels.store) } } label: {
                        VStack(alignment: .leading) {
                            Text(item.filename).lineLimit(1)
                            Text([item.quality, ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file)]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(model.rows) { row in
                    Button { select(row) } label: { rowView(row) }
                }
                if model.loadingCount > 0 { ProgressView() }
                else if libraryItems.isEmpty && model.rows.isEmpty {
                    Text("No streams found").foregroundStyle(.secondary)
                }
            }
        }
        .disabled(picking)
        .task { if let request { await model.load(request) } }
    }

    private func rowView(_ row: StreamPickerModel.Row) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text([row.meta.resolution, row.meta.sizeBytes.map {
                    ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }]
                    .compactMap { $0 }.joined(separator: " · ")).bold()
                if row.meta.cached == true { Image(systemName: "checkmark.circle.fill") }
                if row.meta.cached == false { Text("NOT CACHED").font(.caption2) }
                Spacer()
                Text(row.addon.name).font(.caption).foregroundStyle(.secondary)
            }
            Text(row.stream.displayText).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    private func pick(_ make: @escaping () async throws -> PlayItem) {
        picking = true; status = "Starting…"
        Task {
            defer { picking = false }
            do { onPick(try await make()) } catch { status = error.localizedDescription }
        }
    }

    /// Mirrors StreamPickerSheet.select(_:): uncached rows register, wait, then play.
    private func select(_ row: StreamPickerModel.Row) {
        guard let url = row.stream.httpURL, let request else { return }
        guard row.meta.cached == false else {
            return pick { PlayResolver.playItem(url: url, request: request) }
        }
        picking = true; status = "Adding to debrid…"
        Task {
            defer { picking = false }
            switch await model.registerUncached(row: row) {
            case .added(let service, let id):
                // Failover placement: the resolver URL is bound to the addon's own service.
                guard service == row.intendedService else {
                    status = "Added to \(service); it can't stream from this addon. Try again later."
                    return
                }
                status = "Downloading…"
                if await model.waitUntilDownloaded(service: service, transferID: id) {
                    onPick(PlayResolver.playItem(url: url, request: request))
                } else { status = "Download failed." }
            case .probed: status = "Sent to your debrid service. Try again in a few minutes."
            case .failed(let both): status = both ? "Both services rejected this torrent." : "Couldn't add this torrent."
            }
        }
    }
}
