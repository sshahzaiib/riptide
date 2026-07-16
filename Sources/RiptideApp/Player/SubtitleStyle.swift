import Foundation

/// Global subtitle styling, UserDefaults-backed. Applied to each mpv
/// instance on file load and live from the style controls.
struct SubtitleStyle {
    static let sizeKey = "subFontSize"
    static let posKey = "subPos"
    static let colorKey = "subColor"
    static let defaultSize = 55.0   // mpv's own sub-font-size default
    static let defaultPos = 100     // bottom
    static let defaultColor = "#FFFFFF"

    var fontSize: Double
    var pos: Int
    var color: String

    static func load() -> SubtitleStyle {
        let d = UserDefaults.standard
        let size = d.object(forKey: sizeKey) as? Double ?? defaultSize
        let pos = d.object(forKey: posKey) as? Int ?? defaultPos
        let stored = d.string(forKey: colorKey) ?? defaultColor
        return SubtitleStyle(fontSize: size,
                             pos: pos,
                             color: isValidHex(stored) ? stored : defaultColor)
    }

    static func isValidHex(_ s: String) -> Bool {
        s.count == 7 && s.hasPrefix("#") && s.dropFirst().allSatisfy(\.isHexDigit)
    }
}
