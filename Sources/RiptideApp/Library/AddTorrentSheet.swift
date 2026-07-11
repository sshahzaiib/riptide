import SwiftUI
import UniformTypeIdentifiers
import StreamCore

/// State machine for one add flow. UI-thin: all RD logic lives in TorrentAdder.
@Observable
@MainActor
final class TorrentAddModel {
    enum Phase: Equatable {
        case input
        case adding
        case done
        case error(String)
    }

    var phase: Phase = .input
    var magnetText = ""
    private(set) var lastAdded: TorrentAdder.Added?
    private(set) var source: TorrentAdder.AddSource?
    /// Set when RD terminally rejected the magnet and AllDebrid took it.
    private(set) var adFallback: DebridTransfer?

    var magnetIsValid: Bool {
        magnetText.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("magnet:")
    }

    func submitMagnet() async {
        let magnet = magnetText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard magnet.hasPrefix("magnet:") else {
            phase = .error("Not a magnet link.")
            return
        }
        await run(.magnet(magnet))
    }

    func submit(fileURL: URL) async {
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: fileURL) else {
            phase = .error("Could not read \(fileURL.lastPathComponent).")
            return
        }
        await run(.file(data))
    }

    func reselect(fileIDs: [Int]) async {
        guard let source, let lastAdded else { return }
        phase = .adding
        do {
            let adder = TorrentAdder(rd: RealDebridClient(token: AppSettings.shared.rdToken))
            self.lastAdded = try await adder.reselect(source: source,
                                                      torrentID: lastAdded.torrentID,
                                                      fileIDs: fileIDs)
            phase = .done
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    private func run(_ addSource: TorrentAdder.AddSource) async {
        source = addSource
        phase = .adding
        adFallback = nil
        do {
            let adder = TorrentAdder(rd: RealDebridClient(token: AppSettings.shared.rdToken))
            lastAdded = try await adder.add(addSource)
            phase = .done
        } catch {
            // Backup: magnets RD rejects retry once on AllDebrid. (.torrent
            // file uploads stay RD-only — AD's magnet/upload takes magnets.)
            if case .magnet(let magnet) = addSource,
               !AppSettings.shared.adToken.isEmpty,
               !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                let ad = AllDebridService(client: AllDebridClient(token: AppSettings.shared.adToken))
                if let transfer = try? await ad.addMagnet(magnet) {
                    adFallback = transfer
                    phase = .done
                    return
                }
            }
            phase = .error(error.localizedDescription)
        }
    }
}

/// One sheet for every entry point (toolbar +, drop, paste, magnet: URL).
/// Pass `prefill` to open with a magnet and auto-submit.
struct AddTorrentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model = TorrentAddModel()
    @State private var showFilePicker = false
    @State private var showEditFiles = false
    @State private var autoDismissTask: Task<Void, Never>?
    @State private var hasSubmitted = false
    let prefill: String?
    var torrentFile: URL? = nil
    let onAdded: (TorrentAdder.Added) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Torrent").font(.headline)
            content
        }
        .padding(20)
        .frame(width: 440)
        .fileImporter(isPresented: $showFilePicker,
                      allowedContentTypes: [UTType(filenameExtension: "torrent")
                                            ?? .data]) { result in
            if case .success(let url) = result {
                Task { await model.submit(fileURL: url) }
            }
        }
        .sheet(isPresented: $showEditFiles) {
            if let added = model.lastAdded {
                EditFilesSheet(files: added.files,
                               selected: Set(added.selectedFileIDs)) { ids in
                    Task { await model.reselect(fileIDs: Array(ids).sorted()) }
                }
            }
        }
        .task(id: torrentFile?.absoluteString ?? prefill ?? "") {
            if let torrentFile {
                await model.submit(fileURL: torrentFile)
            } else if let prefill {
                model.magnetText = prefill
                await model.submitMagnet()
            } else if let clip = NSPasteboard.general.string(forType: .string),
                      clip.hasPrefix("magnet:") {
                model.magnetText = clip
            }
        }
        .task(id: model.phase) {
            if case .done = model.phase, model.adFallback == nil, let added = model.lastAdded {
                autoDismissTask = Task {
                    try? await Task.sleep(for: .seconds(2.5))
                    guard !Task.isCancelled else { return }
                    guard !hasSubmitted else { return }
                    hasSubmitted = true
                    onAdded(added)
                    dismiss()
                }
            } else {
                autoDismissTask?.cancel()
                autoDismissTask = nil
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .input:
            TextField("magnet:?xt=urn:btih:…", text: $model.magnetText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await model.submitMagnet() } }
            HStack {
                Button("Choose .torrent…") { showFilePicker = true }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { Task { await model.submitMagnet() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.magnetIsValid)
            }
        case .adding:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Adding to Real-Debrid…").foregroundStyle(.secondary)
            }
        case .done:
            doneView
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Try Again") { model.phase = .input }
            }
        }
    }

    @ViewBuilder
    private var doneView: some View {
        if let transfer = model.adFallback {
            Label("Real-Debrid rejected it — sent to AllDebrid instead.",
                  systemImage: "arrow.triangle.branch")
            Text(transfer.status == .ready
                 ? "AllDebrid already has it cached."
                 : "AllDebrid is downloading it. (AllDebrid items appear in the library in a later update.)")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        } else if let added = model.lastAdded {
            switch added.outcome {
            case .alreadyInLibrary:
                Label("Already in your library.", systemImage: "checkmark.circle")
            case .ready, .downloading:
                Label("Selected \(added.selectedFileIDs.count) video file(s).",
                      systemImage: "checkmark.circle")
                if case .downloading = added.outcome {
                    Text("Real-Debrid is downloading it — it appears in the library once ready.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                if !added.files.isEmpty {
                    Button("Edit Files…") {
                        autoDismissTask?.cancel()
                        autoDismissTask = nil
                        showEditFiles = true
                    }
                }
                Spacer()
                Button("Done") {
                    guard !hasSubmitted else { return }
                    hasSubmitted = true
                    autoDismissTask?.cancel()
                    autoDismissTask = nil
                    onAdded(added)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// Checklist over a torrent's files; confirming re-adds the torrent with
/// the chosen selection (RD can't change selection in place).
private struct EditFilesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let files: [TorrentFile]
    @State var selected: Set<Int>
    let onConfirm: (Set<Int>) -> Void

    init(files: [TorrentFile], selected: Set<Int>, onConfirm: @escaping (Set<Int>) -> Void) {
        self.files = files
        _selected = State(initialValue: selected)
        self.onConfirm = onConfirm
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select Files").font(.headline)
            List(files, id: \.id) { file in
                Toggle(isOn: Binding(
                    get: { selected.contains(file.id) },
                    set: { on in if on { selected.insert(file.id) } else { selected.remove(file.id) } }
                )) {
                    HStack {
                        Text((file.path as NSString).lastPathComponent).lineLimit(1)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: file.bytes,
                                                       countStyle: .file))
                            .foregroundStyle(.secondary).font(.caption)
                    }
                }
            }
            .frame(minHeight: 200)
            Text("Changing the selection re-adds the torrent on Real-Debrid.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    onConfirm(selected)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
