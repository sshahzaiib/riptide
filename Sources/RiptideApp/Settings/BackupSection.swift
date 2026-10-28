import SwiftUI
import AppKit
import UniformTypeIdentifiers
import StreamCore

enum BackupManager {
    static let keychainAccounts = ["rd-token", "ad-token", "tmdb-token", "opensubtitles-key", "media-folder",
                                   "stremio-addons", "trakt-client-id", "trakt-client-secret", "trakt-tokens"]
    static var defaultsDomain: String { Bundle.main.bundleIdentifier ?? "RiptideApp" }

    @MainActor static func makeBackup(store: LibraryStore) throws -> BackupFile {
        let kc = KeychainStore()
        var keys: [String: String] = [:]
        for a in keychainAccounts { if let v = kc.get(a) { keys[a] = v } }
        let domain = UserDefaults.standard.persistentDomain(forName: defaultsDomain) ?? [:]
        return BackupFile(createdAt: Date(), keychain: keys,
                          defaults: try BackupFile.defaultsData(from: domain),
                          history: try store.exportHistory(), watchStates: try store.exportWatchStates())
    }

    @MainActor static func apply(_ backup: BackupFile, store: LibraryStore) throws {
        let defaults = try backup.defaultsDictionary()
        _ = try store.importHistory(backup.history)
        _ = try store.importWatchStates(backup.watchStates)
        let kc = KeychainStore()
        for a in keychainAccounts { if let v = backup.keychain[a] { kc.set(v, account: a) } }
        // ponytail: per-key set (not setPersistentDomain) so AppKit's own keys survive.
        for (k, v) in defaults { UserDefaults.standard.set(v, forKey: k) }
        UserDefaults.standard.synchronize()
    }

    // ponytail: bare-binary dev builds relaunch the executable directly instead of via `open`.
    static func relaunch() {
        let p = Process()
        if Bundle.main.bundlePath.hasSuffix(".app") {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-n", Bundle.main.bundlePath]
        } else {
            p.executableURL = Bundle.main.executableURL
        }
        try? p.run()
        NSApp.terminate(nil)
    }
}

struct BackupSection: View {
    let store: LibraryStore
    @State private var pending: BackupFile?
    @State private var done = false
    @State private var errorMessage: String?
    @State private var errorTitle = "Backup failed"

    private var type: UTType { UTType(exportedAs: "com.northlab.riptide.backup", conformingTo: .json) }

    var body: some View {
        Section("Backup") {
            HStack {
                Button("Back Up…") { backUp() }
                Button("Restore…") { chooseRestore() }
            }
            Text("The backup file includes your API keys and Trakt login. Keep it private.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .alert("Restore backup?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Restore", role: .destructive) {
                guard let b = pending else { return }
                do { try BackupManager.apply(b, store: store); done = true }
                catch { errorTitle = "Restore failed"; errorMessage = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Replace settings on this Mac with the backup from \(pending?.createdAt.formatted(.dateTime) ?? "")?")
        }
        .alert("Restored. Riptide will relaunch.", isPresented: $done) {
            Button("OK") { BackupManager.relaunch() }
        }
        .alert(errorTitle, isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: { Text(errorMessage ?? "") }
    }

    private func backUp() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.allowsOtherFileTypes = true
        panel.nameFieldStringValue = "Riptide-\(Date.now.formatted(.iso8601.year().month().day())).riptide-backup"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try BackupManager.makeBackup(store: store).encoded().write(to: url) }
        catch { errorTitle = "Backup failed"; errorMessage = error.localizedDescription }
    }

    private func chooseRestore() {
        let panel = NSOpenPanel()
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { pending = try BackupFile.decode(Data(contentsOf: url)) }
        catch { errorTitle = "Restore failed"; errorMessage = error.localizedDescription }
    }
}
