import SwiftUI
import StreamCore

/// Settings › Addons: paste a debrid-configured Stremio addon URL
/// (Torrentio, AIOStreams, …). Validated before it's accepted.
struct AddonsSection: View {
    @State private var input = ""
    @State private var validating = false
    @State private var errorMessage: String?
    /// Addon whose URL is loaded into the field for editing; nil = adding.
    @State private var editingID: UUID?
    private var settings: AppSettings { .shared }

    var body: some View {
        Section("Addons (Torrentio, AIOStreams, …)") {
            ForEach(Array(settings.addons.enumerated()), id: \.element.id) { index, addon in
                // LabeledContent, not a bare HStack: the grouped form imposes
                // its label/content column split on rows, starving a leading
                // VStack to a sliver (chars wrapped vertically).
                LabeledContent {
                    Picker("", selection: Binding(
                        get: { addon.service ?? .realDebrid },
                        set: { newValue in
                            var list = settings.addons
                            // Resolve by id, not the render-time index — a row
                            // removed between render and set would misindex.
                            guard let idx = list.firstIndex(where: { $0.id == addon.id })
                            else { return }
                            list[idx].service = newValue
                            settings.saveAddons(list)
                        }
                    )) {
                        ForEach(DebridServiceID.allCases, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .help("Debrid service this addon's streams use")
                    Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.borderless)
                        .disabled(index == 0)
                    Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.borderless)
                        .disabled(index == settings.addons.count - 1)
                    Button { copyURL(addon) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help("Copy addon URL")
                    Button { beginEdit(addon) } label: { Image(systemName: "pencil") }
                        .buttonStyle(.borderless)
                        .help("Edit addon URL")
                    Button(role: .destructive) { remove(addon) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                } label: {
                    Text(addon.name).lineLimit(1)
                    Text(addon.url.host ?? "").lineLimit(1).truncationMode(.middle)
                }
            }
            HStack {
                TextField(editingID == nil ? "Addon manifest URL" : "Edit addon URL", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    // Long pasted URLs must not widen the row (the field's
                    // ideal width tracks its content).
                    .frame(maxWidth: .infinity)
                    .onSubmit(add)
                if validating {
                    ProgressView().controlSize(.small)
                } else {
                    Button(editingID == nil ? "Add" : "Save", action: add)
                        .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                    if editingID != nil {
                        Button("Cancel") { editingID = nil; input = ""; errorMessage = nil }
                    }
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
                // .addon session: 5 s timeout so a dead URL fails fast
                // instead of hanging the spinner for the default ~60 s.
                let validator = AddonValidator(client: StremioAddonClient(session: .addon))
                let result = try await validator.validate(rawURL: raw)
                var list = settings.addons
                guard !list.contains(where: { $0.url == result.baseURL && $0.id != editingID }) else {
                    errorMessage = "That addon is already configured."
                    return
                }
                let detected = DebridServiceID.detect(fromAddonURL: result.baseURL)
                if let idx = list.firstIndex(where: { $0.id == editingID }) {
                    // Edit in place: keep id + position; re-detect service,
                    // falling back to the user's manual pick.
                    list[idx].name = result.manifest.name
                    list[idx].url = result.baseURL
                    list[idx].service = detected ?? list[idx].service
                } else {
                    list.append(ConfiguredAddon(id: UUID(), name: result.manifest.name,
                                                url: result.baseURL, service: detected))
                }
                settings.saveAddons(list)
                editingID = nil
                // Only clear what we validated — don't wipe a newer URL the
                // user typed while this one was still validating.
                if input.trimmingCharacters(in: .whitespaces) == raw { input = "" }
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
        if editingID == addon.id { editingID = nil; input = "" }
    }

    private func copyURL(_ addon: ConfiguredAddon) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(addon.url.absoluteString, forType: .string)
    }

    private func beginEdit(_ addon: ConfiguredAddon) {
        editingID = addon.id
        input = addon.url.absoluteString
        errorMessage = nil
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
