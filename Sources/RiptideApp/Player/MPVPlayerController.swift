import AppKit
import Libmpv

enum PlayerEvent {
    case position(Double)
    case duration(Double)
    case paused(Bool)
    case buffering(Bool)
    case cacheTime(Double)
    case tracksChanged([MPVTrack])
    case ended
    case error(String)     // terminal load/decode failure, surfaced in the window
}

struct MPVTrack: Identifiable, Equatable {
    let id: Int
    let type: String      // "audio" | "sub" | "video"
    let lang: String?
    let title: String?
    let selected: Bool

    var label: String {
        let name = [title, lang].compactMap { $0 }.joined(separator: " · ")
        return name.isEmpty ? "Track \(id)" : name
    }
}

/// mpv host view controller. Render path and lifecycle adapted from MPVKit's
/// macOS demo (MPVMetalViewController.swift): CAMetalLayer handed to mpv as
/// `wid`, vo=gpu-next over MoltenVK, wakeup-callback event loop drained on a
/// serial queue.
/// Layer-hosting video view. SwiftUI does not reliably drive
/// NSViewController.viewDidLayout for layer-hosting views, so the view itself
/// keeps the metal layer glued to its bounds and backing scale.
final class MPVVideoView: NSView {
    let metalLayer = MetalLayer()
    var onResize: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        metalLayer.frame = bounds
        metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = NSColor.black.cgColor
        layer = metalLayer
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func layout() {
        super.layout()
        syncLayer()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncLayer()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncLayer()
    }

    // SwiftUI gestures never see clicks on this AppKit view, so double-click
    // is handled at the AppKit level.
    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() }
        super.mouseUp(with: event)
    }

    private func syncLayer() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        metalLayer.frame = bounds
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale,
                                         height: bounds.height * scale)
        onResize?()
    }
}

final class MPVPlayerController: NSViewController {
    nonisolated(unsafe) static let mpvLogFile: UnsafeMutablePointer<FILE>? =
        ProcessInfo.processInfo.environment["RIPTIDE_MPV_LOG"].flatMap { fopen($0, "w") }
    private let videoView = MPVVideoView(frame: .init(x: 0, y: 0, width: 1280, height: 720))
    var metalLayer: MetalLayer { videoView.metalLayer }
    var mpv: OpaquePointer!
    var onEvent: ((PlayerEvent) -> Void)?
    private lazy var queue = DispatchQueue(label: "mpv", qos: .userInitiated)

    override func loadView() {
        view = videoView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        videoView.onDoubleClick = { [weak self] in self?.toggleFullscreen() }
        videoView.onResize = { [weak self] in self?.scheduleSurfaceAdopt() }
        setupMpv()
    }

    /// MPVKit's 'moltenvk' gpu-context reads the layer's drawableSize ONLY at
    /// VO reconfig and implements no resize event path (its control handler is
    /// VO_NOTIMPL), so mpv keeps its old swapchain forever after a window
    /// resize. Force a reconfig by nudging the aspect override 0.1% and
    /// reverting — imperceptible, and each reconfig re-reads drawableSize.
    private var resizeKick: DispatchWorkItem?
    private func scheduleSurfaceAdopt() {
        guard mpv != nil else { return }
        resizeKick?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.mpv != nil else { return }
            let dar = self.getDouble("video-params/aspect")
            guard dar > 0 else { return }
            mpv_set_property_string(self.mpv, "video-aspect-override",
                                    String(format: "%.6f", dar * 1.001))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, self.mpv != nil else { return }
                mpv_set_property_string(self.mpv, "video-aspect-override", "no")
            }
        }
        resizeKick = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Explicit teardown — MUST be called when the player window closes.
    /// The wakeup callback holds a retained reference to self, so deinit can
    /// never run while mpv is alive; this is the only reliable destruction
    /// point. Safe to call twice (second call no-ops on the nil guard).
    func shutdown() {
        guard mpv != nil else { return }
        mpv_set_wakeup_callback(mpv, nil, nil)
        queue.sync {
            if self.mpv != nil {
                mpv_terminate_destroy(self.mpv)
                self.mpv = nil
            }
        }
        Unmanaged.passUnretained(self).release()
    }

    private func setupMpv() {
        mpv = mpv_create()
        guard mpv != nil else { fatalError("mpv_create failed") }

        // Full mpv log capture for debugging: set RIPTIDE_MPV_LOG=<file path>.
        checkError(mpv_request_log_messages(mpv, Self.mpvLogFile != nil ? "debug" : "warn"))
        checkError(mpv_set_option_string(mpv, "input-media-keys", "yes"))
        // metalLayer is kept alive by self; mpv only needs the pointer value.
        var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(metalLayer).toOpaque()))
        checkError(mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &wid))
        checkError(mpv_set_option_string(mpv, "vo", "gpu-next"))
        checkError(mpv_set_option_string(mpv, "gpu-api", "vulkan"))
        checkError(mpv_set_option_string(mpv, "gpu-context", "moltenvk"))
        checkError(mpv_set_option_string(mpv, "hwdec", "videotoolbox"))
        checkError(mpv_set_option_string(mpv, "ytdl", "no"))
        checkError(mpv_set_option_string(mpv, "keep-open", "yes"))
        if ProcessInfo.processInfo.environment["RIPTIDE_DEBUG_URL"] != nil {
            checkError(mpv_set_option_string(mpv, "loop-file", "inf"))
        }

        checkError(mpv_initialize(mpv))

        mpv_observe_property(mpv, 0, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "paused-for-cache", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "demuxer-cache-time", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "eof-reached", MPV_FORMAT_FLAG)
        // NONE: fires on any change (tracks added, selection moved); we re-read
        // the whole list, so the payload doesn't matter.
        mpv_observe_property(mpv, 0, "track-list", MPV_FORMAT_NONE)

        mpv_set_wakeup_callback(mpv, { ctx in
            guard let ctx else { return }
            let controller = Unmanaged<MPVPlayerController>.fromOpaque(ctx).takeUnretainedValue()
            controller.readEvents()
        }, Unmanaged.passRetained(self).toOpaque())
    }

    // MARK: Commands

    func loadFile(_ url: URL, startAt: Double? = nil) {
        var args = [url.absoluteString, "replace", "-1"]
        if let startAt, startAt > 1 {
            args.append("start=\(Int(startAt))")
        }
        command("loadfile", args: args)
    }

    func togglePause() {
        var paused: Int32 = 0
        mpv_get_property(mpv, "pause", MPV_FORMAT_FLAG, &paused)
        setFlag("pause", paused == 0)
    }

    func seek(to seconds: Double) {
        command("seek", args: [String(seconds), "absolute"])
    }

    func setVolume(_ volume: Double) {
        var v = min(max(volume, 0), 100)
        mpv_set_property(mpv, "volume", MPV_FORMAT_DOUBLE, &v)
    }

    func setSpeed(_ speed: Double) {
        var s = speed
        mpv_set_property(mpv, "speed", MPV_FORMAT_DOUBLE, &s)
    }

    func setMuted(_ muted: Bool) {
        setFlag("mute", muted)
    }

    func toggleFullscreen() {
        guard let window = view.window else { return }
        // SwiftUI windows don't advertise fullscreen capability by default;
        // without this, toggleFullScreen(nil) silently does nothing.
        // SwiftUI stamps data-driven WindowGroup windows .fullScreenNone,
        // which makes toggleFullScreen a silent no-op.
        window.collectionBehavior.remove(.fullScreenNone)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.toggleFullScreen(nil)
    }

    func seek(relative seconds: Double) {
        command("seek", args: [String(seconds), "relative"])
    }

    /// Next chapter if the file has one ahead; otherwise +90s.
    func skipIntro() {
        let chapterCount = getInt("chapter-list/count")
        let current = getInt("chapter")
        if chapterCount > 0, current + 1 < chapterCount {
            var next = Int64(current + 1)
            mpv_set_property(mpv, "chapter", MPV_FORMAT_INT64, &next)
        } else {
            seek(relative: 90)
        }
    }

    func setAudioTrack(id: Int) {
        mpv_set_property_string(mpv, "aid", String(id))
    }

    /// nil disables subtitles.
    func setSubtitleTrack(id: Int?) {
        mpv_set_property_string(mpv, "sid", id.map(String.init) ?? "no")
    }

    func addSubtitle(path: String) {
        command("sub-add", args: [path, "select"])
    }

    private func setFlag(_ name: String, _ flag: Bool) {
        guard mpv != nil else { return }
        var data: Int32 = flag ? 1 : 0
        mpv_set_property(mpv, name, MPV_FORMAT_FLAG, &data)
    }

    private func command(_ command: String, args: [String?] = []) {
        guard mpv != nil else { return }
        var strArgs = args
        strArgs.insert(command, at: 0)
        strArgs.append(nil)
        var cargs = strArgs.map { $0.flatMap { UnsafePointer<CChar>(strdup($0)) } }
        defer { for ptr in cargs where ptr != nil { free(UnsafeMutablePointer(mutating: ptr!)) } }
        checkError(mpv_command(mpv, &cargs))
    }

    // MARK: Property reads

    private func getDouble(_ name: String) -> Double {
        guard mpv != nil else { return 0 }
        var data = Double()
        mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &data)
        return data
    }

    private func getInt(_ name: String) -> Int {
        guard mpv != nil else { return 0 }
        var data = Int64()
        mpv_get_property(mpv, name, MPV_FORMAT_INT64, &data)
        return Int(data)
    }

    private func getString(_ name: String) -> String? {
        guard mpv != nil else { return nil }
        guard let cstr = mpv_get_property_string(mpv, name) else { return nil }
        defer { mpv_free(cstr) }
        return String(cString: cstr)
    }

    private func getFlag(_ name: String) -> Bool {
        guard mpv != nil else { return false }
        var data: Int32 = 0
        mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &data)
        return data != 0
    }

    /// Enumerates track-list via sub-properties (guaranteed stable interface;
    /// avoids MPV_FORMAT_NODE traversal).
    private func currentTracks() -> [MPVTrack] {
        let count = getInt("track-list/count")
        return (0..<count).map { i in
            MPVTrack(id: getInt("track-list/\(i)/id"),
                     type: getString("track-list/\(i)/type") ?? "",
                     lang: getString("track-list/\(i)/lang"),
                     title: getString("track-list/\(i)/title"),
                     selected: getFlag("track-list/\(i)/selected"))
        }
    }

    // MARK: Event loop

    private func readEvents() {
        queue.async { [weak self] in
            guard let self else { return }
            while self.mpv != nil {
                guard let event = mpv_wait_event(self.mpv, 0),
                      event.pointee.event_id != MPV_EVENT_NONE else { break }

                switch event.pointee.event_id {
                case MPV_EVENT_PROPERTY_CHANGE:
                    let dataOpaquePtr = OpaquePointer(event.pointee.data)
                    guard let property = UnsafePointer<mpv_event_property>(dataOpaquePtr)?.pointee else { break }
                    self.handlePropertyChange(property)
                case MPV_EVENT_FILE_LOADED:
                    let tracks = self.currentTracks()
                    let duration = self.getDouble("duration")
                    self.emit(.tracksChanged(tracks))
                    self.emit(.duration(duration))
                case MPV_EVENT_END_FILE:
                    // Spec: mpv load failures surface in the player window.
                    if let end = UnsafePointer<mpv_event_end_file>(OpaquePointer(event.pointee.data))?.pointee,
                       end.reason == MPV_END_FILE_REASON_ERROR {
                        self.emit(.error(String(cString: mpv_error_string(end.error))))
                    } else {
                        self.emit(.ended)
                    }
                case MPV_EVENT_LOG_MESSAGE:
                    if let msg = UnsafePointer<mpv_event_log_message>(OpaquePointer(event.pointee.data))?.pointee,
                       let f = Self.mpvLogFile {
                        fputs("[\(String(cString: msg.prefix))] \(String(cString: msg.text))", f)
                        fflush(f)
                    }
                case MPV_EVENT_SHUTDOWN:
                    break   // destruction is owned by shutdown()
                default:
                    break
                }
            }
        }
    }

    private func handlePropertyChange(_ property: mpv_event_property) {
        let name = String(cString: property.name)
        switch name {
        case "time-pos":
            guard let value = UnsafePointer<Double>(OpaquePointer(property.data))?.pointee else { return }
            emit(.position(value))
        case "duration":
            guard let value = UnsafePointer<Double>(OpaquePointer(property.data))?.pointee else { return }
            emit(.duration(value))
        case "pause":
            guard let value = UnsafePointer<Int32>(OpaquePointer(property.data))?.pointee else { return }
            emit(.paused(value != 0))
        case "paused-for-cache":
            guard let value = UnsafePointer<Int32>(OpaquePointer(property.data))?.pointee else { return }
            emit(.buffering(value != 0))
        case "demuxer-cache-time":
            guard let value = UnsafePointer<Double>(OpaquePointer(property.data))?.pointee else { return }
            emit(.cacheTime(value))
        case "eof-reached":
            guard let value = UnsafePointer<Int32>(OpaquePointer(property.data))?.pointee,
                  value != 0 else { return }
            emit(.ended)
        case "track-list":
            emit(.tracksChanged(currentTracks()))
        default:
            break
        }
    }

    private func emit(_ event: PlayerEvent) {
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(event)
        }
    }

    deinit {
        // Unreachable while mpv is alive (the callback retains self); after
        // shutdown() this no-ops on the nil guard.
        shutdown()
    }

    private func checkError(_ status: CInt) {
        if status < 0 {
            NSLog("mpv error: \(String(cString: mpv_error_string(status)))")
        }
    }
}
