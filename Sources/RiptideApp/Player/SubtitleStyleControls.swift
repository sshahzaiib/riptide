import SwiftUI
import AppKit

/// Size picker + color picker bound to the SubtitleStyle UserDefaults keys.
/// Pass `onChange` to apply edits live to an open player.
struct SubtitleStyleControls: View {
    @AppStorage(SubtitleSize.storageKey) private var size = SubtitleSize.default
    @AppStorage(SubtitleStyle.colorKey) private var colorHex = SubtitleStyle.defaultColor
    // Explicit nil default: a plain optional var gets NO default in the
    // memberwise init, so `SubtitleStyleControls()` wouldn't compile.
    var onChange: ((SubtitleStyle) -> Void)? = nil

    var body: some View {
        Picker("Size", selection: $size) {
            ForEach(SubtitleSize.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        // supportsOpacity: false — subHexString() drops alpha, so an opacity
        // slider would silently discard whatever the user set on it.
        ColorPicker("Color", selection: Binding(
            get: { Color(subHex: colorHex) },
            set: { colorHex = $0.subHexString() }),
                    supportsOpacity: false)
        .onChange(of: size) { notify() }
        .onChange(of: colorHex) { notify() }
    }

    private func notify() { onChange?(SubtitleStyle.load()) }
}

extension Color {
    /// #RRGGBB → Color; malformed input falls back to white.
    init(subHex: String) {
        guard SubtitleStyle.isValidHex(subHex),
              let v = UInt32(subHex.dropFirst(), radix: 16) else {
            self = .white
            return
        }
        self.init(.sRGB,
                  red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }

    /// Color → #RRGGBB (sRGB, alpha dropped — mpv sub-color alpha unused here).
    func subHexString() -> String {
        // Fallback must be an sRGB color: NSColor.white lives in the
        // calibrated-white space and CRASHES on .redComponent.
        let ns = NSColor(self).usingColorSpace(.sRGB)
            ?? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        return String(format: "#%02X%02X%02X",
                      Int((ns.redComponent * 255).rounded()),
                      Int((ns.greenComponent * 255).rounded()),
                      Int((ns.blueComponent * 255).rounded()))
    }
}
