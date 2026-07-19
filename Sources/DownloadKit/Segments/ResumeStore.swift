import Foundation

/// On-disk resume metadata written next to a segmented download as
/// `<destination>.dkpart`. Its presence means "this file is mid-download"; it
/// is deleted on completion. So a MISSING sidecar next to a full-size
/// destination means the download finished — which lets the engine avoid
/// re-downloading a completed file after a crash that lost the DB update.
struct ResumeSidecar: Codable {
    let totalBytes: Int64
    /// ETag or Last-Modified of the entity we started from. Sent back as
    /// `If-Range` so a changed file (debrid re-resolve to a different cache)
    /// forces a clean restart instead of mixing bytes from two entities.
    let validator: String?
    let segments: [SegmentState]
}

public enum ResumeStore {
    public static func sidecarURL(for destination: URL) -> URL {
        URL(fileURLWithPath: destination.path + ".dkpart")
    }
    public static func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func load(_ url: URL) -> ResumeSidecar? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ResumeSidecar.self, from: data)
    }
    static func save(_ sidecar: ResumeSidecar, to url: URL) {
        guard let data = try? JSONEncoder().encode(sidecar) else { return }
        try? data.write(to: url, options: .atomic)   // temp-then-rename: never a torn read
    }
}
