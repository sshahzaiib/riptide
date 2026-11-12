import SwiftUI

struct AddonsList: View {
    let settings: AppSettings
    @State private var pending: ConfiguredAddon?

    var body: some View {
        Section {
            if settings.addons.isEmpty { Text("No addons").foregroundStyle(.secondary) }
            ForEach(settings.addons) { addon in
                HStack {
                    VStack(alignment: .leading) {
                        Text(addon.name)
                        Text(addon.url.host() ?? addon.url.absoluteString)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { move(addon, by: -1) } label: { Image(systemName: "chevron.up") }
                        .disabled(addon.id == settings.addons.first?.id)
                        .accessibilityLabel("Move up")
                    Button { move(addon, by: 1) } label: { Image(systemName: "chevron.down") }
                        .disabled(addon.id == settings.addons.last?.id)
                        .accessibilityLabel("Move down")
                    Button("Remove", role: .destructive) { pending = addon }
                }
            }
        } header: {
            Text("Addons")
        } footer: {
            Text("Play uses the first addon that has a stream; the ones below it are the fallback. Add addons from Set up from another device.")
        }
        .confirmationDialog("Remove \(pending?.name ?? "addon")?", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let a = pending { settings.saveAddons(settings.addons.filter { $0.id != a.id }) }
            }
        }
    }

    private func move(_ addon: ConfiguredAddon, by offset: Int) {
        var list = settings.addons
        guard let i = list.firstIndex(of: addon), list.indices.contains(i + offset) else { return }
        list.swapAt(i, i + offset)
        settings.saveAddons(list)
    }
}
