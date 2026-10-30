import SwiftUI

struct PlaybackSection: View {
    @AppStorage("alwaysShowVersions") private var alwaysShowVersions = false
    @AppStorage(SubtitleSize.storageKey) private var subSize = SubtitleSize.default.rawValue

    var body: some View {
        Section("Playback") {
            Toggle("Always show versions before playing", isOn: $alwaysShowVersions)
            Picker("Subtitle size", selection: $subSize) {
                ForEach(SubtitleSize.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
            }
        }
    }
}
