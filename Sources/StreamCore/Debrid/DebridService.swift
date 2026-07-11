// Sources/StreamCore/Debrid/DebridService.swift
import Foundation

public enum DebridServiceID: String, Codable, CaseIterable, Sendable {
    case realDebrid = "rd"
    case allDebrid = "ad"

    public var displayName: String {
        switch self {
        case .realDebrid: "Real-Debrid"
        case .allDebrid: "AllDebrid"
        }
    }

    /// Torrentio-style addon URLs embed the service name; opaque URLs
    /// (AIOStreams) return nil and the caller decides the default.
    public static func detect(fromAddonURL url: URL) -> DebridServiceID? {
        let s = url.absoluteString.lowercased()
        if s.contains("realdebrid") || s.contains("real-debrid") { return .realDebrid }
        if s.contains("alldebrid") || s.contains("all-debrid") { return .allDebrid }
        return nil
    }
}

public struct DebridTransfer: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case processing(progress: Double)   // 0–100
        case ready
        case failed(String)
    }
    public let id: String
    public let status: Status

    public init(id: String, status: Status) {
        self.id = id
        self.status = status
    }
}

/// What the app does with a debrid account, service-agnostically.
/// Library listing (`libraryEntries`) joins in plan 2.
public protocol DebridService: Sendable {
    var serviceID: DebridServiceID { get }
    /// False for future read-only sources (e.g. a WebDAV adapter).
    var supportsAdds: Bool { get }
    func addMagnet(_ magnet: String) async throws -> DebridTransfer
    func transferStatus(id: String) async throws -> DebridTransfer
    /// Current transfer IDs — the account-diff fallback for hashless picks.
    func transferIDs() async throws -> Set<String>
    /// Finish a transfer another client added (RD: complete file selection).
    func finishForeignAdd(id: String) async throws
    func unrestrict(link: String) async throws -> URL
    func delete(id: String) async throws
    /// Account contents flattened to ready-to-play files. `knownCounts` maps
    /// torrentID -> stored entry count and `cached` the stored entries, so a
    /// fully-expanded pack skips its per-torrent detail RPC on refresh.
    func libraryEntries(knownCounts: [String: Int],
                        cached: [String: [LibraryFileEntry]]) async throws -> [LibraryFileEntry]
}

public extension DebridService {
    func finishForeignAdd(id: String) async throws {}   // most services: nothing to finish
}

// MARK: Real-Debrid adapter

public struct RealDebridService: DebridService {
    let rd: RealDebridClient

    public init(rd: RealDebridClient) { self.rd = rd }

    public var serviceID: DebridServiceID { .realDebrid }
    public var supportsAdds: Bool { true }

    public func addMagnet(_ magnet: String) async throws -> DebridTransfer {
        let adder = TorrentAdder(rd: rd)
        let added = try await adder.add(.magnet(magnet))
        if case .alreadyInLibrary(let id) = added.outcome {
            // A resolver may have added it and left file selection stuck.
            try await adder.completeSelection(torrentID: id)
        }
        return try await transferStatus(id: added.torrentID)
    }

    public func transferStatus(id: String) async throws -> DebridTransfer {
        let info = try await rd.torrentInfo(id)
        let status: DebridTransfer.Status = switch info.status {
        case "downloaded": .ready
        case "magnet_error", "error", "virus", "dead": .failed(info.status)
        default: .processing(progress: info.progress)
        }
        return DebridTransfer(id: id, status: status)
    }

    public func transferIDs() async throws -> Set<String> {
        Set(try await rd.allTorrents().map(\.id))
    }

    public func finishForeignAdd(id: String) async throws {
        try await TorrentAdder(rd: rd).completeSelection(torrentID: id)
    }

    public func unrestrict(link: String) async throws -> URL {
        guard let url = try await rd.unrestrictLink(link).directURL
        else { throw RealDebridError.badResponse }
        return url
    }

    public func delete(id: String) async throws {
        try await rd.deleteTorrent(id)
    }

    public func libraryEntries(knownCounts: [String: Int],
                               cached: [String: [LibraryFileEntry]]) async throws -> [LibraryFileEntry] {
        // Only finished torrents with at least one link are streamable.
        let torrents = try await rd.allTorrents()
            .filter { $0.status == "downloaded" && !$0.links.isEmpty }
        var entries: [LibraryFileEntry] = []
        for t in torrents {
            if t.links.count <= 1 {
                entries.append(LibraryFileEntry(torrentID: t.id, fileIndex: 0,
                                                filename: t.filename, bytes: t.bytes,
                                                added: t.added, link: t.links[0]))
            } else if knownCounts[t.id] == t.links.count, let known = cached[t.id] {
                // Already expanded on a previous refresh — no torrentInfo call.
                entries.append(contentsOf: known)
            } else {
                // Season pack / multi-file: real names live in files[].path.
                let info = try await rd.torrentInfo(t.id)
                let selected = info.files.filter { $0.selected == 1 }
                for (i, file) in selected.enumerated() where i < t.links.count {
                    let base = (file.path as NSString).lastPathComponent
                    entries.append(LibraryFileEntry(torrentID: t.id, fileIndex: i,
                                                    filename: base, bytes: file.bytes,
                                                    added: t.added, link: t.links[i]))
                }
            }
        }
        return entries
    }
}

// MARK: AllDebrid adapter

public struct AllDebridService: DebridService {
    let client: AllDebridClient

    public init(client: AllDebridClient) { self.client = client }

    public var serviceID: DebridServiceID { .allDebrid }
    public var supportsAdds: Bool { true }

    public func addMagnet(_ magnet: String) async throws -> DebridTransfer {
        let up = try await client.magnetUpload(magnet)
        guard let id = up.id else { throw AllDebridError.badResponse }
        return DebridTransfer(id: String(id),
                              status: (up.ready ?? false) ? .ready : .processing(progress: 0))
    }

    public func transferStatus(id: String) async throws -> DebridTransfer {
        guard let numeric = Int(id) else { throw AllDebridError.badResponse }
        let magnet = try await client.magnetStatus(id: numeric)
        let status: DebridTransfer.Status = switch magnet.statusCode {
        case 4: .ready
        case 5...: .failed(magnet.status ?? "error \(magnet.statusCode)")
        default: .processing(progress: magnet.size > 0
            ? Double(magnet.downloaded) / Double(magnet.size) * 100 : 0)
        }
        return DebridTransfer(id: id, status: status)
    }

    public func transferIDs() async throws -> Set<String> {
        Set(try await client.magnetStatusList().map { String($0.id) })
    }

    public func unrestrict(link: String) async throws -> URL {
        try await client.unlock(link: link)
    }

    public func delete(id: String) async throws {
        guard let numeric = Int(id) else { throw AllDebridError.badResponse }
        try await client.magnetDelete(id: numeric)
    }

    public func libraryEntries(knownCounts: [String: Int],
                               cached: [String: [LibraryFileEntry]]) async throws -> [LibraryFileEntry] {
        let ready = try await client.magnetStatusList().filter { $0.statusCode == 4 }
        var entries: [LibraryFileEntry] = []
        for magnet in ready {
            let id = String(magnet.id)
            if let known = cached[id], !known.isEmpty {
                // Ready magnets are immutable — the stored expansion is final.
                entries.append(contentsOf: known)
                continue
            }
            let trees = try await client.magnetFiles(ids: [magnet.id])
            let files = ADFileNode.flattenVideoFiles(trees.flatMap(\.files))
            let added = magnet.uploadDate.map {
                Date(timeIntervalSince1970: TimeInterval($0)).ISO8601Format()
            } ?? ""
            for (i, f) in files.enumerated() {
                entries.append(LibraryFileEntry(service: "ad", torrentID: id,
                                                fileIndex: i, filename: f.name,
                                                bytes: f.size, added: added,
                                                link: f.link))
            }
        }
        return entries
    }
}
