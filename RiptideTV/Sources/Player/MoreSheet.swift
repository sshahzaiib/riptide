import SwiftUI

struct MoreSheet: View {
    static let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
    let model: PlayerModel
    var onClose: () -> Void = {}
    @AppStorage(SubtitleSize.storageKey) private var subSize = SubtitleSize.default.rawValue

    private var inIntro: Bool {
        guard let intro = model.markers.intro else { return false }
        return model.position < intro.upperBound
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Speed") {
                    ForEach(Self.speeds, id: \.self) { s in
                        Button { model.setSpeed(s) } label: {
                            HStack { Text("\(s, specifier: "%g")x"); Spacer()
                                if model.speed == s { Image(systemName: "checkmark") } }
                        }
                    }
                }
                if inIntro || model.markers.creditsStart != nil {
                    Section("Chapters") {
                        if inIntro {
                            Button("Skip intro") { model.skipIntro(); onClose() }
                        }
                        if let credits = model.markers.creditsStart {
                            Button("Skip to credits") { model.seek(to: credits); onClose() }
                        }
                    }
                }
                Section("Subtitle size") {
                    ForEach(SubtitleSize.allCases, id: \.self) { size in
                        Button {
                            subSize = size.rawValue
                            model.applySubtitleStyle(.load())
                        } label: {
                            HStack { Text(size.label); Spacer()
                                if subSize == size.rawValue { Image(systemName: "checkmark") } }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)   // the focused row grows past the list; give it room and let it draw
            .navigationTitle("More")
        }
    }
}
