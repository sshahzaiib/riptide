import SwiftUI
import StreamCore

struct SubSyncOverlay: View {
    enum Focus { case plus }
    let model: PlayerModel
    let onDone: () -> Void
    @FocusState private var focus: Focus?

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 24) {
                Button { model.adjustSubDelay(by: -PlayerModel.subDelayStep) } label: {
                    Image(systemName: "minus")
                }
                Text(PlayerModel.formatMS(model.subDelay))
                    .font(.title2).monospacedDigit().frame(minWidth: 220)
                Button { model.adjustSubDelay(by: PlayerModel.subDelayStep) } label: {
                    Image(systemName: "plus")
                }
                .focused($focus, equals: .plus)
                Button("Reset") { model.resetSubDelay() }.disabled(model.subDelay == 0)
                Button("Done", action: onDone)
            }
            .padding(.horizontal, 40).padding(.vertical, 20)
            .background(.ultraThinMaterial, in: Capsule())
            Text("Subtitles early? press \u{2212}   \u{00B7}   late? press +")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(.top, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .defaultFocus($focus, .plus)
        .onAppear { focus = .plus }
        .onExitCommand(perform: onDone)
    }
}
