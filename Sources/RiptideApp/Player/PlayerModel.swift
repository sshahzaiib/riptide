import AppKit
import Foundation
import Observation
import StreamCore

/// Observable playback state + progress autosave. One instance per player window.
@Observable
@MainActor
final class PlayerModel {
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var paused = false
    private(set) var buffering = false
    private(set) var cacheTime: Double = 0
    private(set) var tracks: [MPVTrack] = []
    private(set) var playbackError: String?
    private(set) var muted = false
    private(set) var speed: Double = 1.0

    var audioTracks: [MPVTrack] { tracks.filter { $0.type == "audio" } }
    var subTracks: [MPVTrack] { tracks.filter { $0.type == "sub" } }

    private weak var controller: MPVPlayerController?
    private let store: LibraryStore
    private let itemKey: String
    private let traktMedia: TraktMedia?
    private var lastSaved: Double = 0
    private var scrobbleStarted = false

    init(store: LibraryStore, itemKey: String, traktMedia: TraktMedia? = nil) {
        self.store = store
        self.itemKey = itemKey
        self.traktMedia = traktMedia
    }

    /// The player's NSWindow — scopes the keyboard event monitor.
    var hostWindow: NSWindow? { controller?.view.window }

    func attach(_ controller: MPVPlayerController) {
        self.controller = controller
        controller.onEvent = { [weak self] event in
            self?.handle(event)
        }
    }

    /// Clamped: seeks/EOF can push position past duration, and Trakt 400s
    /// on progress outside 0...100.
    private var progressPercent: Double {
        duration > 0 ? min(max(position / duration * 100, 0), 100) : 0
    }

    private func scrobble(_ action: TraktScrobbleAction) {
        guard let traktMedia else {
            NSLog("Trakt scrobble \(action.rawValue) SKIPPED — item '\(itemKey)' has no TMDB match")
            return
        }
        TraktService.shared.scrobble(action, media: traktMedia, progress: progressPercent)
    }

    private func handle(_ event: PlayerEvent) {
        switch event {
        case .position(let t):
            position = t
            if !scrobbleStarted, duration > 0 {
                scrobbleStarted = true
                scrobble(.start)
            }
            if abs(t - lastSaved) >= 5 {          // spec: autosave every 5 s
                lastSaved = t
                try? store.saveProgress(itemKey: itemKey, position: t, duration: duration)
            }
        case .duration(let d):   duration = d
        case .paused(let p):
            if scrobbleStarted, p != paused {
                scrobble(p ? .pause : .start)
            }
            paused = p
        case .buffering(let b):  buffering = b
        case .cacheTime(let t):  cacheTime = t
        case .tracksChanged(let t): tracks = t
        case .ended:
            if duration > 0 {
                try? store.saveProgress(itemKey: itemKey, position: duration, duration: duration)
            }
            if scrobbleStarted {
                scrobbleStarted = false
                scrobble(.stop)
            }
        case .error(let message):
            playbackError = message
        }
    }

    /// Flush current position (window closing, app quitting).
    func flushProgress() {
        guard position > 0, duration > 0 else { return }
        try? store.saveProgress(itemKey: itemKey, position: position, duration: duration)
    }

    /// Window closing: persist position, then destroy the mpv instance.
    func shutdown() {
        if scrobbleStarted {
            scrobbleStarted = false
            scrobble(.stop)
        }
        flushProgress()
        controller?.shutdown()
    }

    // MARK: User intents

    func togglePause() { controller?.togglePause() }
    func seek(to seconds: Double) { controller?.seek(to: seconds) }
    func setVolume(_ v: Double) { controller?.setVolume(v) }
    func setAudioTrack(_ id: Int) { controller?.setAudioTrack(id: id) }
    func setSubtitleTrack(_ id: Int?) { controller?.setSubtitleTrack(id: id) }
    func addSubtitle(path: String) { controller?.addSubtitle(path: path) }

    func seek(relative seconds: Double) { controller?.seek(relative: seconds) }
    func toggleMute() {
        muted.toggle()
        controller?.setMuted(muted)
    }
    func setSpeed(_ newSpeed: Double) {
        speed = newSpeed
        controller?.setSpeed(newSpeed)
    }
    func toggleFullscreen() { controller?.toggleFullscreen() }
    func skipIntro() { controller?.skipIntro() }
}
