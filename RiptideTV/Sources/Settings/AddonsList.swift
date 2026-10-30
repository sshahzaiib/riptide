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
                    Button("Remove", role: .destructive) { pending = addon }
                }
            }
        } header: {
            Text("Addons")
        } footer: {
            Text("Add addons from Set up from another device")
        }
        .confirmationDialog("Remove \(pending?.name ?? "addon")?", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let a = pending { settings.saveAddons(settings.addons.filter { $0.id != a.id }) }
            }
        }
    }
}
