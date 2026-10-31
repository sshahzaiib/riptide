import SwiftUI
import StreamCore

struct ControlsOverlay: View {
    enum Focus { case prev, back, playPause, fwd, next, audio, subs, sync, more }
    let model: PlayerModel
    let item: PlayItem
    let hasPrev: Bool
    let hasNext: Bool
    let onPrev: () -> Void
    let onNext: () -> Void
    let onAudio: () -> Void
    let onSubs: () -> Void
    let onSync: () -> Void
    let onMore: () -> Void
    let onInput: () -> Void
    @FocusState private var focus: Focus?

    private var isAddon: Bool { item.itemKey.hasPrefix("addon#") }

    private var titleLine: String {
        guard let s = item.season, let e = item.episode else { return item.title }
        return "\(item.title) · S\(s) E\(e)"
    }

    /// quality · video track text · source. No network: library quality + mpv track + origin.
    private var detailLine: String {
        var parts: [String] = []
        if !isAddon {  // addon stream text is already in PlayItem.title (line 1)
            if let q = AppModels.library.items.first(where: { $0.itemKey == item.itemKey })?.quality {
                parts.append(q)
            }
            if let v = model.tracks.first(where: { $0.type == "video" }),
               let t = v.title, !t.isEmpty { parts.append(t) }
        }
        parts.append(isAddon ? "Addon" : "Real-Debrid")
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Spacer()
            VStack(alignment: .leading, spacing: 6) {
                Text(titleLine).font(.title2.bold()).lineLimit(1)
                Text(detailLine).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            ScrubBar(model: model, onInput: onInput)
            HStack(spacing: 30) {
                button("backward.end.fill", enabled: hasPrev, action: onPrev)
                    .focused($focus, equals: .prev)
                button("gobackward.10") { model.seek(relative: -10) }
                    .focused($focus, equals: .back)
                button(model.paused ? "play.fill" : "pause.fill") { model.togglePause() }
                    .focused($focus, equals: .playPause)
                button("goforward.10") { model.seek(relative: 10) }
                    .focused($focus, equals: .fwd)
                button("forward.end.fill", enabled: hasNext, action: onNext)
                    .focused($focus, equals: .next)
                Spacer()
                button("speaker.wave.2.fill", action: onAudio)
                    .focused($focus, equals: .audio)
                button("captions.bubble.fill", action: onSubs)
                    .focused($focus, equals: .subs)
                button("clock.arrow.trianglehead.counterclockwise.rotate.90", action: onSync)
                    .focused($focus, equals: .sync)
                button("ellipsis", action: onMore)
                    .focused($focus, equals: .more)
            }
        }
        .padding(60)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.85)],
                                   startPoint: .top, endPoint: .bottom))
        .defaultFocus($focus, .playPause)
        .onAppear { focus = .playPause }
        .onChange(of: focus) { onInput() }
    }

    private func button(_ symbol: String, enabled: Bool = true,
                        action: @escaping () -> Void) -> some View {
        Button { onInput(); action() } label: {
            Image(systemName: symbol).font(.title2).frame(width: 44, height: 44)
        }
        .disabled(!enabled)
    }
}
