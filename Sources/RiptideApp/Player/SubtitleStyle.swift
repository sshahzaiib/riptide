import Foundation

/// User-facing subtitle sizes mapped to mpv `sub-font-size` values.
enum SubtitleSize: String, CaseIterable {
    case small
    case medium
    case large
    case extraLarge
    case huge

    static let storageKey = "subSize"
    static let `default`: SubtitleSize = .medium

    static var current: SubtitleSize {
        UserDefaults.standard.string(forKey: storageKey)
            .flatMap(SubtitleSize.init(rawValue:)) ?? .default
    }

    var label: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        case .extraLarge: "Extra Large"
        case .huge: "Huge"
        }
    }

    /// `.medium` is mpv's own sub-font-size default (55).
    var fontSize: Double {
        switch self {
        case .small: 40
        case .medium: 55
        case .large: 70
        case .extraLarge: 85
        case .huge: 100
        }
    }
}

/// Global subtitle styling, UserDefaults-backed. Applied to each mpv
/// instance on file load and live from the style controls.
struct SubtitleStyle {
    static let colorKey = "subColor"
    static let defaultColor = "#FFFFFF"

    /// mpv `sub-pos`: 100 is the bottom edge. Subs lift to `raisedPos` while
    /// the controls pill is on screen so it never covers them.
    /// ponytail: a fixed % of video height, not a measured pill height —
    /// the pill is a fixed-size overlay, so this clears it at any window
    /// size. Measure the pill if a user ever drags it somewhere exotic.
    static let basePos = 100
    static let raisedPos = 88

    var fontSize: Double
    var color: String

    static func load() -> SubtitleStyle {
        let stored = UserDefaults.standard.string(forKey: colorKey) ?? defaultColor
        return SubtitleStyle(fontSize: SubtitleSize.current.fontSize,
                             color: isValidHex(stored) ? stored : defaultColor)
    }

    static func isValidHex(_ s: String) -> Bool {
        s.count == 7 && s.hasPrefix("#") && s.dropFirst().allSatisfy(\.isHexDigit)
    }
}
