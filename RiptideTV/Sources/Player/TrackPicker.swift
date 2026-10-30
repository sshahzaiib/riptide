import SwiftUI
import StreamCore

struct TrackPicker: View {
    enum Kind { case audio, subtitles }
    let kind: Kind
    let model: PlayerModel
    let item: PlayItem
    @Environment(\.dismiss) private var dismiss

    private var tracks: [MPVTrack] { kind == .audio ? model.audioTracks : model.subTracks }
    private var canSearch: Bool { !AppSettings.shared.openSubsKey.isEmpty }

    var body: some View {
        NavigationStack {
            List {
                if kind == .subtitles {
                    Section("Delay (ms)") {
                        HStack {
                            Button("\u{2212}500") { model.adjustSubDelay(by: -0.5) }
                            Button("\u{2212}50") { model.adjustSubDelay(by: -PlayerModel.subDelayStep) }
                            Text(PlayerModel.formatMS(model.subDelay)).monospacedDigit().frame(minWidth: 160)
                            Button("+50") { model.adjustSubDelay(by: PlayerModel.subDelayStep) }
                            Button("+500") { model.adjustSubDelay(by: 0.5) }
                            Button("Reset") { model.resetSubDelay() }.disabled(model.subDelay == 0)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                if kind == .subtitles {
                    row("Off", checked: !tracks.contains { $0.selected }) {
                        model.setSubtitleTrack(nil)
                    }
                }
                ForEach(tracks) { t in
                    row(t.label, checked: t.selected) {
                        if kind == .audio { model.setAudioTrack(t.id) }
                        else { model.setSubtitleTrack(t.id) }
                    }
                }
                if kind == .subtitles && canSearch {
                    NavigationLink("Search OpenSubtitles…") {
                        SubtitleSearchView(model: model, item: item) { dismiss() }
                    }
                }
            }
            .navigationTitle(kind == .audio ? "Audio" : "Subtitles")
        }
    }

    private func row(_ title: String, checked: Bool, _ action: @escaping () -> Void) -> some View {
        Button { action(); dismiss() } label: {
            HStack { Text(title); Spacer(); if checked { Image(systemName: "checkmark") } }
        }
    }
}
