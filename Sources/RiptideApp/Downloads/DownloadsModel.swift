// Sources/RiptideApp/Downloads/DownloadsModel.swift
import AppKit
import Foundation
import Observation
import StreamCore

/// Polls both debrid providers for transfer status; drives the Downloads
/// sidebar section, ready notifications, and the post-ready library refresh.
@Observable
@MainActor
final class DownloadsModel {
    struct Row: Identifiable {
        let serviceID: DebridServiceID
        let transfer: DebridTransfer
        var id: String { "\(serviceID.rawValue)#\(transfer.id)" }
        var isProcessing: Bool {
            if case .processing = transfer.status { true } else { false }
        }
    }

    /// Non-ready transfers, active first. Ready ones live in the library.
    private(set) var rows: [Row] = []
    private(set) var lastUpdated: Date?
    private(set) var pollFailed = false
    /// One-shot message the root view shows as a toast (unbundled-run
    /// fallback for notifications).
    var toastMessage: String?

    var isVisible = false {
        didSet { if isVisible != oldValue { kick() } }
    }

    var activeCount: Int { rows.filter(\.isProcessing).count }

    private let library: LibraryModel
    private let notifier = ReadyNotifier()
    private var pollTask: Task<Void, Never>?
    private var lastStatuses: [String: DebridTransfer.Status] = [:]
    // AD reports no speed — derive it from downloaded-bytes deltas.
    private var lastProgress: [String: (downloadedBytes: Double, at: Date)] = [:]

    init(library: LibraryModel) {
        self.library = library
        notifier.onClick = { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.library.sidebarSelection = .downloads
        }
        notifier.fallback = { [weak self] message in self?.toastMessage = message }
    }

    /// (Re)start the poll loop — view appeared, visibility flipped, or the
    /// stream picker registered an uncached add.
    func kick() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in await self?.poll() }
    }

    private var lastPollAt = Date.distantPast

    private func poll() async {
        while !Task.isCancelled {
            // Debounce: rapid kick()s (sidebar toggling) must not spam the APIs.
            let sinceLast = Date.now.timeIntervalSince(lastPollAt)
            if sinceLast < 3 { try? await Task.sleep(for: .seconds(3 - sinceLast)) }
            guard !Task.isCancelled else { return }
            lastPollAt = .now
            await pollOnce()
            // Idle account → stop polling entirely; the next kick() restarts.
            guard rows.contains(where: \.isProcessing) else { return }
            try? await Task.sleep(for: .seconds(isVisible ? 5 : 30))
        }
    }

    private var services: [any DebridService] {
        let settings = AppSettings.shared
        var services: [any DebridService] = []
        if !settings.rdToken.isEmpty {
            services.append(RealDebridService(rd: RealDebridClient(token: settings.rdToken)))
        }
        if !settings.adToken.isEmpty, !LibraryModel.adAuthRejected {
            services.append(AllDebridService(client: AllDebridClient(token: settings.adToken)))
        }
        return services
    }

    private func pollOnce() async {
        let services = self.services
        var byKey: [String: DebridTransfer] = [:]
        var merged: [Row] = []
        var failed: Set<DebridServiceID> = []
        for service in services {
            guard let transfers = try? await service.activeTransfers() else {
                failed.insert(service.serviceID)
                continue
            }
            for transfer in transfers {
                let row = Row(serviceID: service.serviceID,
                              transfer: withDerivedSpeed(transfer, service: service.serviceID))
                byKey[row.id] = transfer
                if transfer.status != .ready { merged.append(row) }
            }
        }
        // A stale (kick-cancelled) task must not overwrite fresher state.
        guard !Task.isCancelled else { return }
        pollFailed = !failed.isEmpty
        // Total outage: keep the whole last snapshot; RD 429 retry is in the client.
        guard failed.count < services.count else { return }

        // Partial outage: carry the failed provider's last-known state forward
        // so its rows don't vanish and its ready transitions aren't lost.
        var statuses = byKey.mapValues(\.status)
        for serviceID in failed {
            let prefix = "\(serviceID.rawValue)#"
            merged += rows.filter { $0.id.hasPrefix(prefix) }
            for (key, status) in lastStatuses where key.hasPrefix(prefix) {
                statuses[key] = status
            }
        }

        lastUpdated = .now
        rows = merged.sorted {
            ($0.isProcessing ? 0 : 1, $0.transfer.filename) < ($1.isProcessing ? 0 : 1, $1.transfer.filename)
        }
        lastProgress = lastProgress.filter { statuses.keys.contains($0.key) }
        if rows.contains(where: \.isProcessing) { notifier.requestAuthorizationIfNeeded() }
        let ready = TransferDiff.newlyReady(previous: lastStatuses, current: statuses)
        lastStatuses = statuses
        guard !ready.isEmpty else { return }
        for key in ready {
            let name = byKey[key]?.filename ?? ""
            notifier.notifyReady(name: name.isEmpty ? "A download" : name)
        }
        await library.refresh()
    }

    /// AllDebrid speed: bytes-downloaded delta between two consecutive polls.
    private func withDerivedSpeed(_ transfer: DebridTransfer,
                                  service: DebridServiceID) -> DebridTransfer {
        guard transfer.speedBps == nil,
              case .processing(let progress) = transfer.status, transfer.bytes > 0
        else { return transfer }
        let key = "\(service.rawValue)#\(transfer.id)"
        let downloaded = progress / 100 * Double(transfer.bytes)
        defer { lastProgress[key] = (downloaded, .now) }
        guard let prev = lastProgress[key] else { return transfer }
        let elapsed = Date.now.timeIntervalSince(prev.at)
        guard elapsed > 1, downloaded >= prev.downloadedBytes else { return transfer }
        return DebridTransfer(id: transfer.id, status: transfer.status,
                              filename: transfer.filename, bytes: transfer.bytes,
                              speedBps: Int64((downloaded - prev.downloadedBytes) / elapsed),
                              seeders: transfer.seeders)
    }
}
