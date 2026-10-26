import Foundation

/// Last-session shelf snapshots for instant launch paint. Small JSON files;
/// all failures degrade to "no snapshot".
enum ShelfDiskCache {
    private static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.riptide/shelves", isDirectory: true)
    }

    static func load<T: Decodable>(_ type: T.Type, name: String) -> T? {
        let url = directory.appendingPathComponent(name + ".json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let value = try? JSONDecoder().decode(T.self, from: data) else {
            try? FileManager.default.removeItem(at: url)  // corrupt → forget it
            return nil
        }
        return value
    }

    static func save<T: Encodable>(_ value: T, name: String) {
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: directory.appendingPathComponent(name + ".json"),
                        options: .atomic)
    }

    static func remove(name: String) {
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent(name + ".json"))
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}
