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
        for (k, v) in defaults where !(v is NSNull) { UserDefaults.standard.set(v, forKey: k) }
        UserDefaults.standard.synchronize()
    }

    // ponytail: waits for this pid to exit so the new instance never opens library.store while we hold it
    // (a failed open triggers the pre-1.0 wipe). Bare-binary dev builds exec the binary directly.
    /// Returns false if the relaunch helper could not be spawned (app stays running).
    @MainActor static func relaunch() -> Bool {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let launch = Bundle.main.bundlePath.hasSuffix(".app")
            ? "open -n \(q(Bundle.main.bundlePath))"
            : q(Bundle.main.executablePath ?? CommandLine.arguments[0])
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; \(launch)"]
        do { try p.run() } catch { return false }
        NSApp.terminate(nil)
        return true
    }
}

struct BackupSection: View {
    let store: LibraryStore
    @State private var pending: BackupFile?
    @State private var done = false
    @State private var errorMessage: String?
    @State private var errorTitle = "Backup failed"

    private var type: UTType { UTType(filenameExtension: "riptide-backup", conformingTo: .json)! }

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
            Button("OK") { if !BackupManager.relaunch() { errorTitle = "Relaunch failed"; errorMessage = "Restore applied, but Riptide could not relaunch. Quit and reopen it." } }
        } message: { Text("You may need to reconnect Trakt.") }
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
        do {
            try BackupManager.makeBackup(store: store).encoded().write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
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
