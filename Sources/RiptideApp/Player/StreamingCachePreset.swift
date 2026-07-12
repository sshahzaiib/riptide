import Foundation

/// Streaming cache preset (issue #13): user-facing sizes mapped to mpv cache
/// options. Applied pre-init in MPVPlayerController, so a change takes
/// effect in newly opened player windows only.
enum StreamingCachePreset: String, CaseIterable {
    case low
    case `default`
    case aggressive

    static let storageKey = "streamingCachePreset"

    static var current: StreamingCachePreset {
        UserDefaults.standard.string(forKey: storageKey)
            .flatMap(StreamingCachePreset.init(rawValue:)) ?? .default
    }

    var label: String {
        switch self {
        case .low: "Low"
        case .default: "Default"
        case .aggressive: "Aggressive"
        }
    }

    /// mpv option name/value pairs set before mpv_initialize. `default` is
    /// empty so mpv's own network-cache defaults (~150 MiB readahead) apply.
    var mpvOptions: [(name: String, value: String)] {
        switch self {
        case .default:
            []
        case .low:
            [
                ("cache", "yes"),
                ("cache-secs", "10"),
                ("demuxer-max-bytes", "32MiB"),
                ("demuxer-max-back-bytes", "16MiB"),
            ]
        case .aggressive:
            [
                ("cache", "yes"),
                ("cache-secs", "600"),
                ("demuxer-max-bytes", "1GiB"),
                ("demuxer-max-back-bytes", "128MiB"),
                ("stream-buffer-size", "4MiB"),
                ("stream-lavf-o",
                 "reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_delay_max=5"),
            ]
        }
    }
}
