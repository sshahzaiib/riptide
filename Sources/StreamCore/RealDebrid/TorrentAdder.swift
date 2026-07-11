import Foundation

/// Orchestrates adding a magnet/.torrent to Real-Debrid: dedupe by infohash,
/// add, auto-select video files, report whether the result is streamable now.
public struct TorrentAdder: Sendable {
    public enum Outcome: Sendable, Equatable {
        case alreadyInLibrary(torrentID: String)
        case ready(torrentID: String)        // RD status "downloaded"
        case downloading(torrentID: String)  // queued / downloading / …
    }

    public enum AddSource: Sendable {
        case magnet(String)
        case file(Data)
    }

    public struct Added: Sendable, Equatable {
        public let outcome: Outcome
        public let torrentID: String
        public let files: [TorrentFile]       // all files RD listed
        public let selectedFileIDs: [Int]
    }

    let rd: RealDebridClient

    public init(rd: RealDebridClient) { self.rd = rd }

    public func add(_ source: AddSource) async throws -> Added {
        switch source {
        case .magnet(let magnet):
            // Dedupe: same infohash already in the account → don't re-add.
            if let hash = Self.infohash(fromMagnet: magnet),
               let existing = try await rd.allTorrents()
                   .first(where: { $0.hash?.lowercased() == hash }) {
                return Added(outcome: .alreadyInLibrary(torrentID: existing.id),
                             torrentID: existing.id, files: [], selectedFileIDs: [])
            }
            let result = try await rd.addMagnet(magnet)
            return try await finishAdd(id: result.id)
        case .file(let data):
            // ponytail: no pre-add dedupe for .torrent files — hashing the
            // bencoded info dict isn't worth it; RD tolerates duplicates.
            let result = try await rd.addTorrentFile(data)
            return try await finishAdd(id: result.id)
        }
    }

    /// RD rejects selectFiles on an already-selected torrent
    /// (action_already_done), so editing = delete + re-add + select.
    public func reselect(source: AddSource, torrentID: String,
                         fileIDs: [Int]) async throws -> Added {
        try await rd.deleteTorrent(torrentID)
        let result: AddMagnetResult
        switch source {
        case .magnet(let magnet): result = try await rd.addMagnet(magnet)
        case .file(let data): result = try await rd.addTorrentFile(data)
        }
        return try await finishAdd(id: result.id, fileIDs: fileIDs)
    }

    /// Wait for RD to list files, select (explicit ids, else video files,
    /// else all), then map the post-selection status to an outcome.
    private func finishAdd(id: String, fileIDs: [Int]? = nil) async throws -> Added {
        let info: TorrentInfo
        do {
            info = try await rd.pollUntil(id) {
                $0.status == "waiting_files_selection" || $0.status == "downloaded"
            }
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
            throw TorrentAdderError.pollFailed(torrentID: id, underlying: "\(error)")
        }
        var selectedIDs = info.files.filter { $0.selected == 1 }.map(\.id)
        if info.status == "waiting_files_selection" {
            let chosen: [Int]
            if let fileIDs {
                chosen = fileIDs
            } else {
                let videos = Self.videoFiles(in: info.files)
                chosen = (videos.isEmpty ? info.files : videos).map(\.id)
            }
            try await rd.selectFiles(torrentID: id,
                                     files: chosen.map(String.init).joined(separator: ","))
            selectedIDs = chosen
        }
        let after = try await rd.torrentInfo(id)
        let outcome: Outcome = after.status == "downloaded"
            ? .ready(torrentID: id) : .downloading(torrentID: id)
        return Added(outcome: outcome, torrentID: id,
                     files: info.files, selectedFileIDs: selectedIDs)
    }

    /// Finish a torrent another client added but left unselected — e.g. a
    /// Stremio addon resolver that answered before magnet metadata arrived,
    /// leaving RD stuck at "waiting_files_selection" forever. Waits out
    /// metadata resolution, then auto-selects video files. No-ops on
    /// torrents that already started (RD rejects re-selection).
    public func completeSelection(torrentID: String) async throws {
        let info = try await rd.pollUntil(torrentID) { $0.status != "magnet_conversion" }
        guard info.status == "waiting_files_selection" else { return }
        let videos = Self.videoFiles(in: info.files)
        let chosen = (videos.isEmpty ? info.files : videos).map(\.id)
        try await rd.selectFiles(torrentID: torrentID,
                                 files: chosen.map(String.init).joined(separator: ","))
    }

    /// Lowercased infohash embedded in a debrid resolver URL's path
    /// (Torrentio/Comet-style `…/{apikey}/{infohash}/{fileIdx}/{name}`) —
    /// the last 40-hex-char path component, nil when there isn't one.
    public static func infohash(inURL url: URL) -> String? {
        url.pathComponents.last {
            $0.count == 40 && $0.allSatisfy(\.isHexDigit)
        }?.lowercased()
    }

    /// Lowercased infohash from a magnet's `xt=urn:btih:` param, nil otherwise.
    static func infohash(fromMagnet magnet: String) -> String? {
        guard let comps = URLComponents(string: magnet), comps.scheme == "magnet"
        else { return nil }
        for item in comps.queryItems ?? [] where item.name == "xt" {
            if let value = item.value, value.lowercased().hasPrefix("urn:btih:") {
                return String(value.dropFirst("urn:btih:".count)).lowercased()
            }
        }
        return nil
    }

    /// Real video files: known extension, not a sample.
    static func videoFiles(in files: [TorrentFile]) -> [TorrentFile] {
        files.filter { file in
            let ext = (file.path as NSString).pathExtension.lowercased()
            return ReleaseNameParser.videoExtensions.contains(ext)
                && !file.path.lowercased().contains("sample")
        }
    }
}

public enum TorrentAdderError: Error, LocalizedError, Sendable {
    case pollFailed(torrentID: String, underlying: String)
    public var errorDescription: String? {
        switch self {
        case .pollFailed(let id, let underlying):
            "Real-Debrid didn't finish preparing this torrent (\(underlying)). It still exists on Real-Debrid as \(id) — try refreshing the library shortly."
        }
    }
}
