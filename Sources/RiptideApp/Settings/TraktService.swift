import Foundation
import Observation
import StreamCore

/// App-side Trakt facade: Keychain-backed credentials/tokens, one shared
/// client, best-effort wrappers that never throw into UI code.
@Observable
@MainActor
final class TraktService {
    static let shared = TraktService()

    private let keychain = KeychainStore()
    private(set) var clientID: String
    private(set) var clientSecret: String
    private(set) var tokens: TraktTokens?
    private(set) var needsReauth = false
    private(set) var client: TraktClient?
    /// Session cache: "movie-603"/"show-1399" -> user rating.
    private var ratingsCache: [String: Int]?
    /// Dedupes the initial ratings fetch when several menus appear at once.
    private var ratingsFetch: Task<[String: Int], Never>?

    init() {
        clientID = keychain.get("trakt-client-id") ?? ""
        clientSecret = keychain.get("trakt-client-secret") ?? ""
        if let raw = keychain.get("trakt-tokens"),
           let decoded = try? JSONDecoder().decode(TraktTokens.self, from: Data(raw.utf8)) {
            tokens = decoded
        }
        rebuildClient()
    }

    var isConfigured: Bool { !clientID.isEmpty && !clientSecret.isEmpty }
    var isConnected: Bool { tokens != nil }

    private func rebuildClient() {
        guard isConfigured else { client = nil; return }
        let built = TraktClient(clientID: clientID, clientSecret: clientSecret, tokens: tokens)
        built.cache = .shared
        built.onTokensRefreshed = { [weak self] fresh in self?.persist(tokens: fresh) }
        client = built
    }

    private func persist(tokens: TraktTokens?) {
        self.tokens = tokens
        if let tokens, let data = try? JSONEncoder().encode(tokens),
           let raw = String(data: data, encoding: .utf8) {
            keychain.set(raw, account: "trakt-tokens")
        } else {
            keychain.delete(account: "trakt-tokens")
        }
    }

    func saveCredentials(clientID: String, clientSecret: String) {
        let newID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        // Tokens belong to the old app registration — stale ones can never
        // refresh and would wedge the service in needsReauth.
        if newID != self.clientID, isConnected { persist(tokens: nil) }
        self.clientID = newID
        self.clientSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        keychain.set(self.clientID, account: "trakt-client-id")
        keychain.set(self.clientSecret, account: "trakt-client-secret")
        rebuildClient()
    }

    func disconnect() {
        persist(tokens: nil)
        needsReauth = false
        ratingsCache = nil
        ratingsFetch?.cancel()
        ratingsFetch = nil
        rebuildClient()
        Task { await MetadataCache.shared.remove(prefix: TraktClient.userCachePrefix) }
        FavoritesModel.shared.reset()
        WatchlistModel.shared.reset()
        UpNextModel.shared.reset()
        DiscoverModel.shared.reset()
    }

    // MARK: Device flow

    func requestDeviceCode() async throws -> TraktDeviceCode {
        guard let client else { throw TraktError.unauthorized }
        return try await client.requestDeviceCode()
    }

    /// Polls until authorized, denied, or the code expires. True on success.
    /// Transient network/server errors keep polling; only denial aborts.
    func awaitAuthorization(code: TraktDeviceCode) async -> Bool {
        guard let client else { return false }
        let deadline = Date().addingTimeInterval(TimeInterval(code.expiresIn))
        while Date() < deadline, !Task.isCancelled {
            do {
                if let fetched = try await client.pollDeviceToken(deviceCode: code.deviceCode) {
                    persist(tokens: fetched)
                    needsReauth = false
                    return true
                }
            } catch TraktError.denied {
                return false
            } catch {
                // Transient failure — sleep and retry until the code expires.
            }
            try? await Task.sleep(for: .seconds(code.interval))
        }
        return false
    }

    // MARK: Best-effort wrappers

    func scrobble(_ action: TraktScrobbleAction, media: TraktMedia, progress: Double) {
        guard let client, isConnected else {
            NSLog("Trakt scrobble \(action.rawValue) SKIPPED — not connected")
            return
        }
        NSLog("Trakt scrobble \(action.rawValue) \(media) @\(String(format: "%.1f", progress))%")
        Task {
            do {
                let response = try await client.scrobble(action, media: media, progress: progress)
                NSLog("Trakt scrobble \(action.rawValue) OK: \(String(data: response, encoding: .utf8)?.prefix(400) ?? "")")
            }
            catch TraktError.unauthorized {
                needsReauth = true
                NSLog("Trakt scrobble \(action.rawValue) FAILED: unauthorized (reconnect needed)")
            }
            catch { NSLog("Trakt scrobble \(action.rawValue) FAILED: \(error)") }
        }
    }

    /// Manual watched marks. Best-effort like scrobble — local state is
    /// already written by the caller; Trakt failures only log.
    func setWatched(_ watched: Bool, media: [TraktMedia]) {
        guard let client, isConnected, !media.isEmpty else { return }
        Task {
            do {
                if watched { try await client.addToHistory(media) }
                else { try await client.removeFromHistory(media) }
                NSLog("Trakt history \(watched ? "add" : "remove") OK (\(media.count) item(s))")
            }
            catch TraktError.unauthorized {
                needsReauth = true
                NSLog("Trakt history \(watched ? "add" : "remove") FAILED: unauthorized")
            }
            catch { NSLog("Trakt history \(watched ? "add" : "remove") FAILED: \(error)") }
        }
    }

    /// Best-effort remote episode states for one show: "season#episode" ->
    /// (progress 0…1, finished). Each fetch fails independently so playback
    /// progress still renders when the watched-history call errors (and vice
    /// versa). A completed mark wins over a stale paused entry — the caller's
    /// question is "did I already watch this?".
    func showEpisodeStates(tmdbID: Int) async -> [String: (progress: Double, finished: Bool)]? {
        guard let client, isConnected else { return nil }
        var states: [String: (progress: Double, finished: Bool)] = [:]
        do {
            for entry in try await client.playback()
            where entry.type == "episode" && entry.show?.ids.tmdb == tmdbID {
                if let ep = entry.episode, entry.progress > 0 {
                    states["\(ep.season)#\(ep.number)"] = (entry.progress / 100, false)
                }
            }
        } catch TraktError.unauthorized { needsReauth = true; return nil }
        catch {}
        do {
            if let show = try await client.watchedShows()
                .first(where: { $0.show.ids.tmdb == tmdbID }),
               let traktID = show.show.ids.trakt {
                for season in try await client.showProgress(traktID: traktID,
                                                            lastActivity: show.lastWatchedAt).seasons {
                    for ep in season.episodes where ep.completed {
                        states["\(season.number)#\(ep.number)"] = (1, true)
                    }
                }
            }
        } catch TraktError.unauthorized { needsReauth = true; return nil }
        catch {}
        return states
    }



    /// TEMP: dump Trakt's current playback-progress state (RIPTIDE_TRAKT_PROBE=1).
    func probePlayback() async {
        guard let client, isConnected else { return }
        do {
            for p in try await client.playback() {
                NSLog("PROBE playback: type=\(p.type) show=\(p.show?.ids.tmdb ?? -1) ep=\(p.episode.map { "S\($0.season)E\($0.number)" } ?? "-") movie=\(p.movie?.ids.tmdb ?? -1) progress=\(p.progress) pausedAt=\(p.pausedAt.map(String.init(describing:)) ?? "nil")")
            }
        } catch { NSLog("PROBE playback failed: \(error)") }
    }

    func pullSync(store: LibraryStore) async {
        guard let client, isConnected else {
            NSLog("Trakt pull SKIPPED — not connected")
            return
        }
        do {
            let summary = try await TraktSyncer(client: client, store: store).pull()
            NSLog("Trakt pull OK: playbackApplied=\(summary.playbackApplied) watchedApplied=\(summary.watchedApplied)")
        } catch TraktError.unauthorized {
            needsReauth = true
            NSLog("Trakt pull FAILED: unauthorized (reconnect needed)")
        } catch {
            NSLog("Trakt sync failed: \(error)")
        }
    }

    func rating(for media: TraktMedia) async -> Int? {
        guard let client, isConnected else { return nil }
        if ratingsCache == nil {
            if ratingsFetch == nil {
                ratingsFetch = Task {
                    var cache: [String: Int] = [:]
                    if let movies = try? await client.ratedMovies() {
                        for entry in movies {
                            if let id = entry.movie?.ids.tmdb { cache["movie-\(id)"] = entry.rating }
                        }
                    }
                    if let shows = try? await client.ratedShows() {
                        for entry in shows {
                            if let id = entry.show?.ids.tmdb { cache["show-\(id)"] = entry.rating }
                        }
                    }
                    return cache
                }
            }
            ratingsCache = await ratingsFetch?.value
            ratingsFetch = nil
        }
        return ratingsCache?[cacheKey(media)]
    }

    func rate(media: TraktMedia, rating: Int) {
        guard let client, isConnected else { return }
        ratingsCache?[cacheKey(media)] = rating
        Task {
            do { try await client.rate(media: media, rating: rating) }
            catch TraktError.unauthorized { needsReauth = true }
            catch { NSLog("Trakt rate failed: \(error)") }
        }
    }

    private func cacheKey(_ media: TraktMedia) -> String {
        switch media {
        case .movie(let id): "movie-\(id)"
        case .show(let id), .episode(let id, _, _): "show-\(id)"
        }
    }
}

extension TraktMedia {
    /// nil when the item is unmatched (invisible to Trakt).
    init?(playItem: PlayItem) {
        guard let id = playItem.tmdbID else { return nil }
        if let season = playItem.season, let episode = playItem.episode {
            self = .episode(showTMDBID: id, season: season, episode: episode)
        } else {
            self = .movie(tmdbID: id)
        }
    }
}
