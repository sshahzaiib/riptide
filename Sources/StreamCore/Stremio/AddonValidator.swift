import Foundation

/// Add-time gate: an addon URL is accepted only if it is a reachable Stremio
/// stream addon AND proves a debrid service is configured (its stream probe
/// returns at least one resolved http(s) URL rather than P2P infohashes).
public struct AddonValidator: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case invalidURL
        case unreachable
        case notAnAddon
        case noStreamSupport
        case noDebrid
    }

    public struct Result: Sendable {
        public let baseURL: URL
        public let manifest: AddonManifest
    }

    /// The Shawshank Redemption — universally seeded; every working
    /// stream addon returns results for it.
    public static let probeIMDBID = "tt0111161"

    let client: StremioAddonClient

    public init(client: StremioAddonClient = StremioAddonClient()) {
        self.client = client
    }

    public func validate(rawURL: String) async throws -> Result {
        guard let base = StremioAddonClient.normalizedBase(from: rawURL) else {
            throw Failure.invalidURL
        }

        let manifest: AddonManifest
        do {
            manifest = try await client.manifest(baseURL: base)
        } catch is StremioAddonError {
            throw Failure.notAnAddon          // 404 or non-manifest body
        } catch {
            if error.isCancellation { throw error }
            throw Failure.unreachable         // transport-level (URLError)
        }
        guard manifest.supportsStreams else { throw Failure.noStreamSupport }

        let streams: [AddonStream]
        do {
            streams = try await client.streams(baseURL: base, type: .movie,
                                               imdbID: Self.probeIMDBID)
        } catch is StremioAddonError {
            throw Failure.noDebrid            // addon exists but can't serve streams
        } catch {
            if error.isCancellation { throw error }
            throw Failure.unreachable
        }
        guard streams.contains(where: { $0.httpURL != nil }) else {
            throw Failure.noDebrid
        }
        return Result(baseURL: base, manifest: manifest)
    }
}

extension Error {
    /// Task cancellation must never be re-mapped to a domain failure
    /// (same passthrough as TorrentAdder's poll loop).
    var isCancellation: Bool {
        self is CancellationError || (self as? URLError)?.code == .cancelled
    }
}
