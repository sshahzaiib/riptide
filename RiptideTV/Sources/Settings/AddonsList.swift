import SwiftUI

struct AddonsList: View {
    let settings: AppSettings
    @State private var pending: ConfiguredAddon?

    var body: some View {
        Section {
            if settings.addons.isEmpty { Text("No addons").foregroundStyle(.secondary) }
            // One focusable button per row: tvOS focuses a List row as a whole,
            // so buttons nested in a row can't be reached with the remote and
            // the row's text doesn't adapt to the focus highlight.
            ForEach(settings.addons) { addon in
                Button { pending = addon } label: {
                    VStack(alignment: .leading) {
                        Text(addon.name)
                        Text(addon.url.host() ?? addon.url.absoluteString)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Addons")
        } footer: {
            Text("Play uses the first addon that has a stream; the ones below it are the fallback. Select an addon to move or remove it. Add addons from Set up from another device.")
        }
        .confirmationDialog(pending?.name ?? "Addon", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            if let addon = pending {
                if addon.id != settings.addons.first?.id { Button("Move Up") { move(addon, by: -1) } }
                if addon.id != settings.addons.last?.id { Button("Move Down") { move(addon, by: 1) } }
                Button("Remove", role: .destructive) {
                    settings.saveAddons(settings.addons.filter { $0.id != addon.id })
                }
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
