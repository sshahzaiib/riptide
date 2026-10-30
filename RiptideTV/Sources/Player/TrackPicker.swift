import SwiftUI
import StreamCore

struct TrackPicker: View {
    enum Kind { case audio, subtitles }
    let kind: Kind
    let model: PlayerModel
    let item: PlayItem
    var onSync: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    private var tracks: [MPVTrack] { kind == .audio ? model.audioTracks : model.subTracks }
    private var canSearch: Bool { !AppSettings.shared.openSubsKey.isEmpty }

    var body: some View {
        NavigationStack {
            List {
                if kind == .subtitles {
                    Button("Subtitle sync…") { onSync() }
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
