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
final class MPVPlayerController: NSViewController {
    var metalLayer = MetalLayer()
    var mpv: OpaquePointer!
    var onEvent: ((PlayerEvent) -> Void)?
    private lazy var queue = DispatchQueue(label: "mpv", qos: .userInitiated)

    override func loadView() {
        view = NSView(frame: .init(x: 0, y: 0, width: 1280, height: 720))
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        metalLayer.frame = view.frame
        metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = NSColor.black.cgColor
        view.layer = metalLayer
        view.wantsLayer = true
        setupMpv()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard let window = view.window else { return }
        let scale = window.screen?.backingScaleFactor ?? 2
        let size = view.bounds.size
        metalLayer.frame = CGRect(origin: .zero, size: size)
        metalLayer.drawableSize = CGSize(width: size.width * scale,
                                         height: size.height * scale)
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

        checkError(mpv_request_log_messages(mpv, "warn"))
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

        checkError(mpv_initialize(mpv))

        mpv_observe_property(mpv, 0, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "paused-for-cache", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "demuxer-cache-time", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "eof-reached", MPV_FORMAT_FLAG)

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
