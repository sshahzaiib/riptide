import StreamCore

@MainActor
enum AppModels {
    // tvOS may purge the on-disk container; fall back to memory rather than crash.
    static let store: LibraryStore = (try? LibraryStore.onDisk()) ?? (try! LibraryStore.inMemory())
}
