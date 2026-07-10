import SwiftUI
import StreamCore

/// Settings › Addons: paste a debrid-configured Stremio addon URL
/// (Torrentio, AIOStreams, …). Validated before it's accepted.
struct AddonsSection: View {
    @State private var input = ""
    @State private var validating = false
    @State private var errorMessage: String?
    private var settings: AppSettings { .shared }

    var body: some View {
        Section("Addons (Torrentio, AIOStreams, …)") {
            ForEach(Array(settings.addons.enumerated()), id: \.element.id) { index, addon in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(addon.name)
                        Text(addon.url.host ?? "")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.borderless)
                        .disabled(index == 0)
                    Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.borderless)
                        .disabled(index == settings.addons.count - 1)
                    Button(role: .destructive) { remove(addon) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("Addon manifest URL", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                if validating {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Add", action: add)
                        .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            Text("Paste an addon URL that has a debrid service (Real-Debrid, TorBox, …) configured. The URL embeds your debrid key and is stored in the Keychain.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func add() {
        let raw = input.trimmingCharacters(in: .whitespaces)
        guard !validating, !raw.isEmpty else { return }
        validating = true
        errorMessage = nil
        Task {
            defer { validating = false }
            do {
                let result = try await AddonValidator().validate(rawURL: raw)
                var list = settings.addons
                guard !list.contains(where: { $0.url == result.baseURL }) else {
                    errorMessage = "That addon is already configured."
                    return
                }
                list.append(ConfiguredAddon(id: UUID(), name: result.manifest.name,
                                            url: result.baseURL))
                settings.saveAddons(list)
                input = ""
            } catch let failure as AddonValidator.Failure {
                errorMessage = failure.userMessage
            } catch {
                errorMessage = AddonValidator.Failure.unreachable.userMessage
            }
        }
    }

    private func move(_ index: Int, by offset: Int) {
        var list = settings.addons
        list.swapAt(index, index + offset)
        settings.saveAddons(list)
    }

    private func remove(_ addon: ConfiguredAddon) {
        settings.saveAddons(settings.addons.filter { $0.id != addon.id })
    }
}

extension AddonValidator.Failure {
    var userMessage: String {
        switch self {
        case .invalidURL:
            "That doesn't look like a valid URL."
        case .unreachable:
            "Couldn't reach the addon — check the URL and your connection."
        case .notAnAddon:
            "That URL isn't an addon."
        case .noStreamSupport:
            "That addon doesn't provide streams."
        case .noDebrid:
            "This addon has no debrid service configured. Open the addon's configure page, connect Real-Debrid (or another debrid service), and paste the new URL."
        }
    }
}
