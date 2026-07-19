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

    public init(url: URL, destination: URL, totalBytes: Int64, segments: [SegmentState],
                session: URLSession, globalLimiter: RateLimiter? = nil, bytesPerSecond: Double = 0) {
        self.url = url; self.destination = destination; self.totalBytes = totalBytes
        self.segments = segments; self.session = session
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
    }

    private func preallocate() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: destination.path) { fm.createFile(atPath: destination.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(max(0, totalBytes)))   // grow-to-size preserves existing bytes
    }
}
