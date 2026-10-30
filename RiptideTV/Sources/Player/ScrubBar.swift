import SwiftUI

func clock(_ seconds: Double) -> String {
    let s = max(0, Int(seconds))
    let (h, m, sec) = (s / 3600, s / 60 % 60, s % 60)
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
}

struct ScrubBar: View {
    let model: PlayerModel
    var onInput: () -> Void = {}
    @FocusState private var focused: Bool

    private var fraction: Double {
        model.duration > 0 ? min(1, max(0, model.position / model.duration)) : 0
    }

    var body: some View {
        HStack(spacing: 20) {
            Text(clock(model.position)).monospacedDigit()
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(.white).frame(width: geo.size.width * fraction)
                    Circle().fill(.white)
                        .frame(width: focused ? 28 : 18, height: focused ? 28 : 18)
                        .offset(x: geo.size.width * fraction - (focused ? 14 : 9))
                }
                .frame(height: 8).frame(maxHeight: .infinity)
            }
            .frame(height: 30)
            Text("-" + clock(model.duration - model.position)).monospacedDigit()
            if model.buffering { ProgressView() }
        }
        .focusable()
        .focused($focused)
        .onChange(of: focused) { onInput() }
        .onMoveCommand { dir in
            onInput()
            switch dir {
            case .left: model.seek(relative: -10)
            case .right: model.seek(relative: 10)
            default: break
            }
        }
    }
}
