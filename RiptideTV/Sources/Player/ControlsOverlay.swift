import SwiftUI
import StreamCore

struct ControlsOverlay: View {
    enum Focus { case playPause }
    let model: PlayerModel
    let item: PlayItem
    let hasPrev: Bool
    let hasNext: Bool
    let onPrev: () -> Void
    let onNext: () -> Void
    let onAudio: () -> Void
    let onSubs: () -> Void
    let onMore: () -> Void
    let onInput: () -> Void
    @FocusState private var focus: Focus?

    private var titleLine: String {
        guard let s = item.season, let e = item.episode else { return item.title }
        return "\(item.title) · S\(s) E\(e)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Spacer()
            Text(titleLine).font(.title2.bold()).lineLimit(1)
            ScrubBar(model: model, onInput: onInput)
            HStack(spacing: 30) {
                button("backward.end.fill", enabled: hasPrev, action: onPrev)
                button("gobackward.10") { model.seek(relative: -10) }
                button(model.paused ? "play.fill" : "pause.fill") { model.togglePause() }
                    .focused($focus, equals: .playPause)
                button("goforward.10") { model.seek(relative: 10) }
                button("forward.end.fill", enabled: hasNext, action: onNext)
                Spacer()
                button("speaker.wave.2.fill", action: onAudio)
                button("captions.bubble.fill", action: onSubs)
                button("ellipsis", action: onMore)
            }
        }
        .padding(60)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.85)],
                                   startPoint: .top, endPoint: .bottom))
        .defaultFocus($focus, .playPause)
        .onAppear { focus = .playPause }
    }

    private func button(_ symbol: String, enabled: Bool = true,
                        action: @escaping () -> Void) -> some View {
        Button { onInput(); action() } label: {
            Image(systemName: symbol).font(.title2).frame(width: 44, height: 44)
        }
        .disabled(!enabled)
    }
}
