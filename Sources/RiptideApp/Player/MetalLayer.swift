import Foundation
import QuartzCore
#if canImport(AppKit)
import AppKit
#endif

// Adapted from MPVKit's macOS demo (Demo/Demo-macOS/Player/Metal/MetalLayer.swift).
// Both overrides work around MoltenVK behaviors; see
// https://github.com/mpv-player/mpv/pull/13651
final class MetalLayer: CAMetalLayer {
    // MoltenVK momentarily forces drawableSize to 1x1 to complete presentation;
    // letting that through causes flicker and can leave the size stuck at 1x1.
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }

    // EDR activation only takes effect from the main thread.
    override var wantsExtendedDynamicRangeContent: Bool {
        get { super.wantsExtendedDynamicRangeContent }
        set {
            if Thread.isMainThread {
                super.wantsExtendedDynamicRangeContent = newValue
            } else {
                DispatchQueue.main.sync {
                    super.wantsExtendedDynamicRangeContent = newValue
                }
            }
        }
    }
}
