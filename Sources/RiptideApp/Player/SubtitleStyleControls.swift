import SwiftUI
import AppKit

/// Sliders + color picker bound to the SubtitleStyle UserDefaults keys.
/// Pass `onChange` to apply edits live to an open player.
struct SubtitleStyleControls: View {
    @AppStorage(SubtitleStyle.sizeKey) private var fontSize = SubtitleStyle.defaultSize
    @AppStorage(SubtitleStyle.posKey) private var pos = SubtitleStyle.defaultPos
    @AppStorage(SubtitleStyle.colorKey) private var colorHex = SubtitleStyle.defaultColor
    // Explicit nil default: a plain optional var gets NO default in the
    // memberwise init, so Task 4's `SubtitleStyleControls()` wouldn't compile.
    var onChange: ((SubtitleStyle) -> Void)? = nil

    var body: some View {
        Slider(value: $fontSize, in: 20...120, step: 1) {
            Text("Size")
        } minimumValueLabel: { Text("A").font(.caption2) }
          maximumValueLabel: { Text("A").font(.title3) }
        Slider(value: Binding(get: { Double(pos) }, set: { pos = Int($0) }),
               in: 0...100, step: 1) {
            Text("Position")
        } minimumValueLabel: { Image(systemName: "arrow.up.to.line").font(.caption2) }
          maximumValueLabel: { Image(systemName: "arrow.down.to.line").font(.caption2) }
        ColorPicker("Color", selection: Binding(
            get: { Color(subHex: colorHex) },
            set: { colorHex = $0.subHexString() }))
        .onChange(of: fontSize) { notify() }
        .onChange(of: pos) { notify() }
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
