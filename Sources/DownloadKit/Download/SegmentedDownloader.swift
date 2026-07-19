import Foundation

public actor SegmentedDownloader {
    private let url: URL
    private let destination: URL
    private let totalBytes: Int64
    private var segments: [SegmentState]
    private let session: URLSession
    private let limiters: [RateLimiter]
    private var inFlight: Task<Void, Error>?
    private var cancelled = false

    /// When set, segment progress is persisted here so an interrupted download
    /// resumes from disk on a later run. `validator` is the entity tag we
    /// started from (sent as If-Range by each segment). Writes are throttled
    /// and pushed off the actor onto a serial queue so disk I/O never stalls
    /// the download task group.
    private let resumeURL: URL?
    private let validator: String?
    private var lastPersist: TimeInterval = 0
    private let persistQueue = DispatchQueue(label: "com.northlab.riptide.dkpart")

    public init(url: URL, destination: URL, totalBytes: Int64, segments: [SegmentState],
                session: URLSession, globalLimiter: RateLimiter? = nil, bytesPerSecond: Double = 0,
                resumeURL: URL? = nil, validator: String? = nil) {
        self.url = url; self.destination = destination; self.totalBytes = totalBytes
        self.segments = segments; self.session = session
        self.resumeURL = resumeURL; self.validator = validator
        var ls: [RateLimiter] = []
        if let globalLimiter { ls.append(globalLimiter) }
        if bytesPerSecond > 0 { ls.append(RateLimiter(bytesPerSecond: bytesPerSecond)) }
        self.limiters = ls
    }

    public func snapshot() -> [SegmentState] { segments }
    public func cancel() {
        cancelled = true
        inFlight?.cancel()
    }

    public func download(onProgress: @escaping @Sendable (Int64) async -> Void) async throws -> [SegmentState] {
        try preallocate()
        do {
            try await runGroup(onProgress: onProgress)
        } catch is CancellationError {
            return segments                                   // partial snapshot preserved
        } catch DownloadError.rangeUnsupported {
            if cancelled { return segments }
            // A segment hit a 200 it couldn't own → abandon segmentation, single stream from 0.
            segments = planSegments(totalBytes: totalBytes, count: 1)
            try preallocate()
            do { try await runGroup(onProgress: onProgress) }
            catch is CancellationError { return segments }
        }
        // Success — drop the resume sidecar. Queued on the same serial queue as
        // the progress writes, so it always runs after any in-flight persist
        // (never a resurrected sidecar next to a finished file).
        if let resumeURL { persistQueue.async { ResumeStore.delete(resumeURL) } }
        return segments
    }

    private func runGroup(onProgress: @escaping @Sendable (Int64) async -> Void) async throws {
        let work = Task { [self] in
            try await withThrowingTaskGroup(of: Void.self) { group in
                for segment in snapshot() where !segment.isComplete {
                    let seg = segment, url = self.url, dest = self.destination
                    let session = self.session, limiters = self.limiters, total = self.totalBytes
                    group.addTask {
                        let handle = try FileHandle(forWritingTo: dest)
                        defer { try? handle.close() }
                        _ = try await SegmentRunner.run(
                            url: url, segment: seg, fileHandle: handle, session: session,
                            limiters: limiters, totalBytes: total
                        ) { delta in
                            await self.bump(index: seg.index, delta: delta)   // sole writer, awaited in order
                            await onProgress(delta)
                        }
                    }
                }
                try await group.waitForAll()
            }
        }
        inFlight = work
        try await work.value
    }

    private func bump(index: Int, delta: Int64) {
        guard let i = segments.firstIndex(where: { $0.index == index }) else { return }
        segments[i].downloaded += delta
        persistIfDue()
    }

    /// Throttled resume-sidecar write. bump() is the sole, serialized mutator of
    /// `segments`, so the snapshot captured here is consistent; the actual disk
    /// write is dispatched off-actor. Skipped once cancelled so a paused/aborted
    /// download can't recreate the sidecar the app just deleted.
    private func persistIfDue() {
        guard let resumeURL, !cancelled, !Task.isCancelled else { return }
        let now = nowSeconds()
        guard now - lastPersist >= 2 else { return }   // ponytail: ≤2s of progress lost on a hard crash
        lastPersist = now
        let snapshot = ResumeSidecar(totalBytes: totalBytes, validator: validator, segments: segments)
        persistQueue.async { ResumeStore.save(snapshot, to: resumeURL) }
    }

    private func preallocate() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: destination.path) { fm.createFile(atPath: destination.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(max(0, totalBytes)))   // grow-to-size preserves existing bytes
    }
}
