import Foundation
import Observation
import AppKit
import StreamCore
import class StreamCore.LibraryItem
import DownloadKit

@MainActor
@Observable
final class LocalDownloadManager {
    private let store: LibraryStore
    private let queue: DownloadQueue
    private var idToKey: [UUID: String] = [:]
    private var keyToId: [String: UUID] = [:]
    private struct Pending { let path: String; let title: String; let filename: String }
    private var pending: [String: Pending] = [:]
    /// Updates that arrived before their id→key mapping was registered.
    /// `queue.add` is `await`ed, so the event pump can deliver a `.queued`
    /// or even a terminal `.completed`/`.failed` update during that suspension
    /// — before `idToKey[id]` is set. Buffer the latest such update per id and
    /// replay it once `download` finishes registering the mapping, so a fast
    /// terminal event can't be lost (which would strand the record in
    /// `.downloading` forever).
    private var orphanUpdates: [UUID: QueueUpdate] = [:]

    /// Live progress for in-flight downloads, keyed by itemKey.
    private(set) var active: [String: DownloadProgress] = [:]
    var activeCount: Int { active.count }

    init(store: LibraryStore, maxConcurrent: Int = 3) {
        self.store = store
        self.queue = DownloadQueue(maxConcurrent: maxConcurrent)
    }

    /// Begin consuming queue events and reconcile persisted state. Call once.
    func start() {
        let events = queue.events
        Task { [weak self] in
            for await update in events { self?.handle(update) }
        }
        Task { await reconcile() }
    }

    func download(_ item: LibraryItem) async {
        guard let root = AppSettings.shared.mediaFolderURL else { return }
        if isDownloaded(item.itemKey) { return }
        let dest = DownloadPaths.destination(root: root, for: item)
        do {
            let url = try await DebridResolver.directURL(for: item)
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            let id = await queue.add(DownloadRequest(url: url, destination: dest, connections: 8))
            idToKey[id] = item.itemKey
            keyToId[item.itemKey] = id
            pending[item.itemKey] = Pending(path: dest.path, title: item.title,
                                            filename: item.filename)
            active[item.itemKey] = DownloadProgress(bytesDownloaded: 0, totalBytes: nil,
                                                    bytesPerSecond: 0, phase: .queued)
            try? store.upsertDownload(itemKey: item.itemKey, localPath: dest.path,
                state: .downloading, totalBytes: 0, downloadedBytes: 0,
                title: item.title, filename: item.filename)
            // Replay any event that landed during the `await queue.add` above,
            // now that the id→key mapping and pending info exist.
            if let buffered = orphanUpdates.removeValue(forKey: id) { handle(buffered) }
        } catch {
            try? store.upsertDownload(itemKey: item.itemKey, localPath: dest.path,
                state: .failed, totalBytes: 0, downloadedBytes: 0,
                title: item.title, filename: item.filename, errorMessage: "\(error)")
        }
    }

    func cancel(itemKey: String) {
        if let id = keyToId[itemKey] { Task { await queue.cancel(id) } }
        let path = pending[itemKey]?.path
            ?? (try? store.downloadRecord(itemKey: itemKey))?.localPath
        clear(itemKey)
        if let path { try? FileManager.default.removeItem(atPath: path) }
        try? store.deleteDownload(itemKey: itemKey)
    }

    func deleteLocal(itemKey: String) {
        if let rec = try? store.downloadRecord(itemKey: itemKey) {
            try? FileManager.default.removeItem(atPath: rec.localPath)
        }
        try? store.deleteDownload(itemKey: itemKey)
    }

    func reveal(itemKey: String) {
        guard let rec = try? store.downloadRecord(itemKey: itemKey) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: rec.localPath)])
    }

    func isDownloaded(_ itemKey: String) -> Bool {
        guard let rec = try? store.downloadRecord(itemKey: itemKey) else { return false }
        return rec.state == .completed && FileManager.default.fileExists(atPath: rec.localPath)
    }

    func progress(_ itemKey: String) -> DownloadProgress? { active[itemKey] }

    func displayTitle(_ itemKey: String) -> String {
        pending[itemKey]?.title
            ?? (try? store.downloadRecord(itemKey: itemKey))?.title
            ?? itemKey
    }

    func completedRecords() -> [DownloadRecord] {
        ((try? store.completedDownloads()) ?? []).sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: Private

    private func handle(_ update: QueueUpdate) {
        guard let key = idToKey[update.id] else {
            // Mapping not registered yet — stash and let `download` replay it.
            orphanUpdates[update.id] = update
            return
        }
        let info = pending[key]
        switch update.progress.phase {
        case .completed:
            clear(key)
            try? store.upsertDownload(itemKey: key, localPath: info?.path ?? "",
                state: .completed,
                totalBytes: update.progress.totalBytes ?? update.progress.bytesDownloaded,
                downloadedBytes: update.progress.bytesDownloaded,
                title: info?.title ?? key, filename: info?.filename ?? "")
        case .failed(let msg):
            clear(key)
            try? store.upsertDownload(itemKey: key, localPath: info?.path ?? "",
                state: .failed, totalBytes: update.progress.totalBytes ?? 0,
                downloadedBytes: update.progress.bytesDownloaded,
                title: info?.title ?? key, filename: info?.filename ?? "", errorMessage: msg)
        default:
            active[key] = update.progress
        }
    }

    private func clear(_ key: String) {
        if let id = keyToId[key] { idToKey[id] = nil }
        active[key] = nil
        keyToId[key] = nil
        pending[key] = nil
    }

    private func reconcile() async {
        let records = (try? store.allDownloads()) ?? []
        let plan = DownloadReconciler.plan(
            records: records.map { ($0.itemKey, $0.state, $0.localPath) },
            fileExists: { FileManager.default.fileExists(atPath: $0) })
        for key in plan.markMissing {
            let rec = records.first { $0.itemKey == key }
            try? store.upsertDownload(itemKey: key, localPath: "", state: .failed,
                totalBytes: 0, downloadedBytes: 0,
                title: rec?.title ?? key, filename: rec?.filename ?? "",
                errorMessage: "File missing")
        }
        for key in plan.requeue {
            if let item = try? store.item(itemKey: key) { await download(item) }
            else { try? store.deleteDownload(itemKey: key) }
        }
    }
}
