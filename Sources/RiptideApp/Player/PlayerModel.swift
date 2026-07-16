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
    private(set) var ended = false
    private(set) var isMiniPlayer = false

    var audioTracks: [MPVTrack] { tracks.filter { $0.type == "audio" } }
    var subTracks: [MPVTrack] { tracks.filter { $0.type == "sub" } }

    private weak var controller: MPVPlayerController?
    private let store: LibraryStore
    private var itemKey: String
    private(set) var subDelay: Double = 0
    private var subtitleStateAppliedFor: String?
    private var traktMedia: TraktMedia?
    private var lastSaved: Double = 0
    private var scrobbleStarted = false
    private var sleepActivity: NSObjectProtocol?
    private var savedNormalFrame: NSRect?
    private var savedCollectionBehavior: NSWindow.CollectionBehavior = []
    private var fullscreenExitObserver: NSObjectProtocol?

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
        controller.onFullscreenIntent = { [weak self] in self?.toggleFullscreen() }
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
        let progress = progressPercent
        // Trakt 422s on any scrobble under 1% and on pause at >= 80% (past the
        // watched threshold it expects stop, which we send on ended/shutdown).
        if progress < 1 || (action == .pause && progress >= 80) {
            NSLog("Trakt scrobble \(action.rawValue) SKIPPED — progress \(String(format: "%.1f", progress))% outside Trakt's accepted range")
            return
        }
        TraktService.shared.scrobble(action, media: traktMedia, progress: progress)
    }

    /// Hold a display-sleep assertion while video is actually playing.
    private func setSleepDisabled(_ disabled: Bool) {
        if disabled, sleepActivity == nil {
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: .idleDisplaySleepDisabled,
                reason: "Video playback")
        } else if !disabled, let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }
    }

    private func handle(_ event: PlayerEvent) {
        switch event {
        case .position(let t):
            position = t
            // keep-open holds the last frame; a user seek back from the end
            // resumes position events — clear the end state so the overlay
            // logic re-arms.
            if ended, duration > 0, t < duration - 2 { ended = false }
            if !scrobbleStarted, duration > 0 {
                scrobbleStarted = true
                scrobble(.start)
                setSleepDisabled(!paused)
            }
            // duration == 0 means the next file hasn't loaded yet (advance
            // resets it) — a stale old-file position event must not be saved
            // under the new itemKey.
            if duration > 0, abs(t - lastSaved) >= 5 {   // spec: autosave every 5 s
                lastSaved = t
                try? store.saveProgress(itemKey: itemKey, position: t, duration: duration)
            }
        case .duration(let d):   duration = d
        case .paused(let p):
            if scrobbleStarted, p != paused {
                scrobble(p ? .pause : .start)
            }
            paused = p
            setSleepDisabled(!p && duration > 0)
        case .buffering(let b):  buffering = b
        case .cacheTime(let t):  cacheTime = t
        case .tracksChanged(let t):
            tracks = t
            applyPerFileSubtitleState()
            if ProcessInfo.processInfo.environment["RIPTIDE_DEBUG_SUB"] != nil {
                NSLog("RIPTRACKS: \(t.map { "\($0.type)#\($0.id)\($0.selected ? "*" : "")" }.joined(separator: " "))")
            }
        case .ended:
            ended = true
            if duration > 0 {
                try? store.saveProgress(itemKey: itemKey, position: duration, duration: duration)
            }
            if scrobbleStarted {
                scrobbleStarted = false
                scrobble(.stop)
            }
            setSleepDisabled(false)
        case .error(let message):
            playbackError = message
            setSleepDisabled(false)
        }
    }

    /// Flush current position (window closing, app quitting).
    func flushProgress() {
        guard position > 0, duration > 0 else { return }
        try? store.saveProgress(itemKey: itemKey, position: position, duration: duration)
    }

    /// Window closing: persist position, then destroy the mpv instance.
    func shutdown() {
        clearFullscreenExitObserver()
        if scrobbleStarted {
            scrobbleStarted = false
            scrobble(.stop)
        }
        setSleepDisabled(false)
        flushProgress()
        controller?.shutdown()
    }

    /// In-window switch to the next episode: close out the old item's
    /// scrobble, swap identity, reset per-file state, and load the new URL
    /// into the live mpv instance. (.ended already saved the old item's
    /// final progress.)
    func advance(to next: PlayItem) {
        // ponytail: the mini aspect lock can't be re-derived here (the next
        // file's aspect is unknown until it loads) — just unlock; the next
        // manual mini enter re-locks.
        if isMiniPlayer { hostWindow?.resizeIncrements = NSSize(width: 1, height: 1) }
        flushProgress()
        if scrobbleStarted {
            scrobbleStarted = false
            scrobble(.stop)
        }
        itemKey = next.itemKey
        traktMedia = TraktMedia(playItem: next)
        position = 0
        duration = 0
        lastSaved = 0
        cacheTime = 0
        tracks = []
        playbackError = nil
        ended = false
        buffering = false
        subDelay = 0
        controller?.setSubDelay(0)
        // nil (not "leave the old key"): advancing to the SAME itemKey
        // (replay, or debug-URL streams where itemKey == "") would otherwise
        // fail the inequality guard and skip the style/delay re-apply.
        subtitleStateAppliedFor = nil
        // speed deliberately survives the swap: like volume/mute it's a
        // session preference (a 1.25x binge stays 1.25x), and mpv itself
        // persists it across loadfile.
        controller?.loadFile(next.url, startAt: next.resumeFrom)
        controller?.play()
    }

    // MARK: User intents

    func togglePause() { controller?.togglePause() }
    func seek(to seconds: Double) { controller?.seek(to: seconds) }
    func setVolume(_ v: Double) { controller?.setVolume(v) }
    func setAudioTrack(_ id: Int) { controller?.setAudioTrack(id: id) }
    func setSubtitleTrack(_ id: Int?) { controller?.setSubtitleTrack(id: id) }
    func addSubtitle(path: String) { controller?.addSubtitle(path: path) }

    static let subDelayStep = 0.05  // 50 ms, VLC's default

    func adjustSubDelay(by delta: Double) {
        subDelay += delta
        controller?.setSubDelay(subDelay)
        controller?.showOSD("Sub delay: \(Self.formatMS(subDelay))")
        persistSubDelay()
    }

    func resetSubDelay() {
        subDelay = 0
        controller?.setSubDelay(0)
        controller?.showOSD("Sub delay: 0 ms")
        persistSubDelay()
    }

    func applySubtitleStyle(_ style: SubtitleStyle) {
        controller?.setSubStyle(fontSize: style.fontSize, pos: style.pos, color: style.color)
    }

    static func formatMS(_ seconds: Double) -> String {
        let ms = Int((seconds * 1000).rounded())
        if ms == 0 { return "0 ms" }
        return ms < 0 ? "−\(-ms) ms" : "+\(ms) ms"  // U+2212 minus, per spec copy
    }

    private func persistSubDelay() {
        guard !itemKey.isEmpty else { return }  // debug-URL playback: session-only
        let key = "subDelay.\(itemKey)"
        // Rounded-ms zero check: repeated ±0.05 accumulation can leave
        // float dust (e.g. 1e-17) that a strict == 0 would persist forever.
        if Int((subDelay * 1000).rounded()) == 0 {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(subDelay, forKey: key)
        }
    }

    /// Style + persisted delay, once per item. Re-runs after an
    /// autoplay advance because itemKey changes.
    private func applyPerFileSubtitleState() {
        guard subtitleStateAppliedFor != itemKey else { return }
        subtitleStateAppliedFor = itemKey
        applySubtitleStyle(SubtitleStyle.load())
        let stored = itemKey.isEmpty
            ? 0 : UserDefaults.standard.double(forKey: "subDelay.\(itemKey)")
        subDelay = stored
        controller?.setSubDelay(stored)
        if stored != 0 {
            controller?.showOSD("Sub delay restored: \(Self.formatMS(stored))")
        }
    }

    func seek(relative seconds: Double) { controller?.seek(relative: seconds) }
    func toggleMute() {
        muted.toggle()
        controller?.setMuted(muted)
    }
    func setSpeed(_ newSpeed: Double) {
        speed = newSpeed
        controller?.setSpeed(newSpeed)
    }
    func toggleFullscreen() {
        if isMiniPlayer { exitMiniPlayer() }   // spec: mini → fullscreen exits mini first
        controller?.toggleFullscreen()
    }
    func skipIntro() { controller?.skipIntro() }

    // MARK: Mini player (issue #11)

    func toggleMiniPlayer() {
        isMiniPlayer ? exitMiniPlayer() : enterMiniPlayer()
    }

    private func enterMiniPlayer() {
        guard let window = hostWindow else { return }
        // A pending observer means a fullscreen-exit transition is already
        // in flight — re-entering would re-toggle fullscreen mid-transition.
        guard fullscreenExitObserver == nil else { return }
        // From native fullscreen: exit first, enter mini once the window is
        // back to a normal frame (one-shot observer; also cleared in
        // shutdown() so closing mid-transition can't leak it).
        if window.styleMask.contains(.fullScreen) {
            fullscreenExitObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didExitFullScreenNotification,
                object: window, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.clearFullscreenExitObserver()
                    self.enterMiniPlayer()
                }
            }
            window.toggleFullScreen(nil)
            return
        }
        savedNormalFrame = window.frame
        savedCollectionBehavior = window.collectionBehavior
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        let raw = controller?.videoAspect ?? 0
        // Lock only when the aspect is known — a pre-load 16:9 guess must not
        // stay stuck on a 4:3 file. The fallback drives the frame size only.
        if raw > 0 { window.contentAspectRatio = NSSize(width: raw, height: 1) }
        let aspect = raw > 0 ? raw : 16.0 / 9.0
        window.contentMinSize = NSSize(width: 320, height: 180)
        let size = NSSize(width: 480, height: 480 / aspect)
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        let origin = NSPoint(x: screen.maxX - size.width - 20, y: screen.minY + 20)
        window.setFrame(NSRect(origin: origin, size: size),
                        display: true, animate: true)
        isMiniPlayer = true
    }

    private func exitMiniPlayer() {
        guard let window = hostWindow else { return }
        // contentAspectRatio and resizeIncrements are mutually exclusive in
        // AppKit — resetting increments to 1×1 clears the aspect lock.
        window.resizeIncrements = NSSize(width: 1, height: 1)
        window.level = .normal
        window.collectionBehavior = savedCollectionBehavior
        window.isMovableByWindowBackground = false
        // No animation: an in-flight frame animation fights the min-size
        // bump below and a follow-on fullscreen transition (mini → f), and
        // mpv's debounced VO-reconfig renders the upscale blurry mid-flight.
        if let frame = savedNormalFrame {
            window.setFrame(frame, display: true)
        }
        savedNormalFrame = nil
        window.contentMinSize = NSSize(width: 800, height: 450)
        isMiniPlayer = false
    }

    private func clearFullscreenExitObserver() {
        if let fullscreenExitObserver {
            NotificationCenter.default.removeObserver(fullscreenExitObserver)
        }
        fullscreenExitObserver = nil
    }
}
