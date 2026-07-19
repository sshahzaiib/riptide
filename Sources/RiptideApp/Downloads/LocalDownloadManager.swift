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

    /// Live progress for in-flight downloads, keyed by itemKey. Updates many
    /// times per download — only the popover (which shows live bytes) should
    /// observe this.
    private(set) var active: [String: DownloadProgress] = [:]
    /// Which itemKeys are downloading. Changes only on start/finish — views
    /// that just need "is it downloading" (detail buttons, context menus)
    /// observe this instead of `active`, so a progress tick can't rebuild an
    /// open menu (which SwiftUI does by dismiss + re-present → flicker).
    private(set) var downloadingKeys: Set<String> = []
    var activeCount: Int { downloadingKeys.count }
    func isDownloading(_ itemKey: String) -> Bool { downloadingKeys.contains(itemKey) }

    /// The engine emits a progress event per network chunk (hundreds/sec).
    /// Publishing each one to `active` re-renders every SwiftUI view that
    /// observes it — including whole detail pages — so coalesce non-terminal
    /// updates to a few per second per download. Terminal states bypass this.
    private var lastUIPublish: [String: TimeInterval] = [:]
    private let uiPublishInterval: TimeInterval = 0.25

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
        Task {
            await reconcile()
            importExternalFiles()
        }
    }

    /// Adopt files placed in the media folder by something other than the
    /// internal downloader (e.g. downloaded from the AllDebrid website).
    /// Matches a file to a library item by exact filename — the internal
    /// downloader saves each file as `item.filename`, and an external
    /// download of the same link carries that same release name — and writes
    /// a `.completed` record so play-from-local, the badge, and the popover
    /// all recognise it. Only fills gaps: never touches an item already
    /// downloading or already recorded complete.
    /// Returns the number of files newly adopted this pass.
    // ponytail: full recursive walk of the media folder — fine for a personal
    // library. If it ever points at a huge tree, switch to a direct
    // DownloadPaths.destination path-check per item.
    @discardableResult
    func importExternalFiles() -> Int {
        guard let root = AppSettings.shared.mediaFolderURL else { return 0 }
        var index: [String: URL] = [:]   // filename -> path (first match wins)
        if let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in walker where index[url.lastPathComponent] == nil {
                index[url.lastPathComponent] = url
            }
        }
        guard !index.isEmpty, let items = try? store.items() else { return 0 }
        var adopted = 0
        for item in items where !item.filename.isEmpty {
            guard let url = index[item.filename] else { continue }
            let existing = try? store.downloadRecord(itemKey: item.itemKey)
            if existing?.state == .downloading || existing?.state == .completed { continue }
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            try? store.upsertDownload(itemKey: item.itemKey, localPath: url.path,
                state: .completed, totalBytes: size, downloadedBytes: size,
                title: title(for: item), filename: item.filename)
            adopted += 1
        }
        return adopted
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
            pending[item.itemKey] = Pending(path: dest.path, title: title(for: item),
                                            filename: item.filename)
            downloadingKeys.insert(item.itemKey)
            active[item.itemKey] = DownloadProgress(bytesDownloaded: 0, totalBytes: nil,
                                                    bytesPerSecond: 0, phase: .queued)
            try? store.upsertDownload(itemKey: item.itemKey, localPath: dest.path,
                state: .downloading, totalBytes: 0, downloadedBytes: 0,
                title: title(for: item), filename: item.filename)
            // Replay any event that landed during the `await queue.add` above,
            // now that the id→key mapping and pending info exist.
            if let buffered = orphanUpdates.removeValue(forKey: id) { handle(buffered) }
        } catch {
            try? store.upsertDownload(itemKey: item.itemKey, localPath: dest.path,
                state: .failed, totalBytes: 0, downloadedBytes: 0,
                title: title(for: item), filename: item.filename, errorMessage: "\(error)")
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
        // Prefer a live library lookup so episodes read "Show SxxEyy" (the
        // record's own title is the show name for episodes). Fall back to the
        // stored title when the library item is gone.
        if let item = try? store.item(itemKey: itemKey) { return title(for: item) }
        return pending[itemKey]?.title
            ?? (try? store.downloadRecord(itemKey: itemKey))?.title
            ?? itemKey
    }

    /// Display title for a download: "Show SxxEyy" for episodes, else the
    /// plain title. Persisted on the record so it survives library deletion.
    private func title(for item: LibraryItem) -> String {
        guard let s = item.season, let e = item.episode else { return item.title }
        return String(format: "%@ S%02dE%02d", item.title, s, e)
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
            let now = ProcessInfo.processInfo.systemUptime
            if let last = lastUIPublish[key], now - last < uiPublishInterval { return }
            lastUIPublish[key] = now
            active[key] = update.progress
        }
    }

    private func clear(_ key: String) {
        if let id = keyToId[key] { idToKey[id] = nil }
        active[key] = nil
        downloadingKeys.remove(key)
        keyToId[key] = nil
        pending[key] = nil
        lastUIPublish[key] = nil
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
