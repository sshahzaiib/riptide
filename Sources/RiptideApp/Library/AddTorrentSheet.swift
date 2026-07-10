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
        do {
            let adder = TorrentAdder(rd: RealDebridClient(token: AppSettings.shared.rdToken))
            lastAdded = try await adder.add(addSource)
            phase = .done
        } catch {
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
        .task {
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
        if let added = model.lastAdded {
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
                // Task 6 replaces this stub with the edit-files sheet trigger.
                Spacer()
                Button("Done") {
                    onAdded(added)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}
