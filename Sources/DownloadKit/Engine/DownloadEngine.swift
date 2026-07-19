import Foundation

public actor DownloadEngine {
    private let session: URLSession
    private let globalLimiter: RateLimiter?

    public init(session: URLSession = DownloadEngine.makeSession(connections: 8),
                globalLimiter: RateLimiter? = nil) {
        self.session = session; self.globalLimiter = globalLimiter
    }

    /// Cache-free session sized for N concurrent connections (avoids RAM bloat on huge files).
    public static func makeSession(connections: Int) -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpMaximumConnectionsPerHost = max(6, connections)
        return URLSession(configuration: c)
    }

    public nonisolated func start(url: URL, destination: URL, connections: Int = 8,
                                  bytesPerSecond: Double = 0) -> AsyncStream<DownloadProgress> {
        AsyncStream { continuation in
            let task = Task {
                await self.run(url: url, destination: destination, connections: connections,
                               bytesPerSecond: bytesPerSecond, continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(url: URL, destination: URL, connections: Int, bytesPerSecond: Double,
                     continuation: AsyncStream<DownloadProgress>.Continuation) async {
        let emitter = Emitter(continuation: continuation, start: nowSeconds())
        continuation.yield(.init(bytesDownloaded: 0, totalBytes: nil, bytesPerSecond: 0, phase: .probing))
        do {
            let probe = try await RangeProbe.probe(url: url, session: session)

            // Unknown size (chunked / no Content-Length): single sequential stream, no preallocate.
            guard let total = probe.contentLength, total > 0 else {
                continuation.yield(.init(bytesDownloaded: 0, totalBytes: nil, bytesPerSecond: 0, phase: .downloading))
                let done = try await streamWhole(url: url, destination: destination,
                                                 bytesPerSecond: bytesPerSecond, emitter: emitter)
                continuation.yield(.init(bytesDownloaded: done, totalBytes: nil, bytesPerSecond: 0, phase: .completed))
                continuation.finish(); return
            }

            let count = probe.acceptsRanges ? max(1, connections) : 1
            let sidecarURL = ResumeStore.sidecarURL(for: destination)
            var segments = planSegments(totalBytes: total, count: count)
            var validator = probe.validator

            // Resume path (ranged servers only). Reuse the saved segment offsets
            // when they still describe the same entity and the preallocated file
            // is intact; otherwise start fresh.
            if probe.acceptsRanges {
                let saved = ResumeStore.load(sidecarURL)
                if let saved, saved.totalBytes == total,
                   fileSize(destination) == total, segmentsCover(saved.segments, total) {
                    segments = saved.segments
                    validator = saved.validator ?? probe.validator
                } else if saved == nil, fileSize(destination) == total {
                    // No sidecar next to a full-size file ⇒ a finished download
                    // whose DB update was lost (crash between finish and record
                    // write). Any *incomplete* download keeps a sidecar from the
                    // start, so this is safe: adopt it as complete, don't redo it.
                    continuation.yield(.init(bytesDownloaded: total, totalBytes: total,
                                             bytesPerSecond: 0, phase: .completed))
                    continuation.finish(); return
                }
            }

            // Sidecar fully complete (crash right before the engine's own delete).
            if segments.allSatisfy(\.isComplete) {
                ResumeStore.delete(sidecarURL)
                continuation.yield(.init(bytesDownloaded: total, totalBytes: total,
                                         bytesPerSecond: 0, phase: .completed))
                continuation.finish(); return
            }

            let alreadyDone = segments.reduce(Int64(0)) { $0 + $1.downloaded }
            await emitter.seed(alreadyDone)
            // Write the marker synchronously BEFORE the download preallocates the
            // file — so a crash right after preallocation (full-size zeros) always
            // has a sidecar and can't be mistaken for a completed file.
            ResumeStore.save(ResumeSidecar(totalBytes: total, validator: validator, segments: segments),
                             to: sidecarURL)
            let downloader = SegmentedDownloader(
                url: url, destination: destination, totalBytes: total, segments: segments,
                session: session, globalLimiter: globalLimiter, bytesPerSecond: bytesPerSecond,
                resumeURL: sidecarURL, validator: validator)

            continuation.yield(.init(bytesDownloaded: alreadyDone, totalBytes: total,
                                     bytesPerSecond: 0, phase: .downloading))
            _ = try await downloader.download { delta in await emitter.record(delta, total: total) }
            let done = await emitter.total
            continuation.yield(.init(bytesDownloaded: done, totalBytes: total, bytesPerSecond: 0, phase: .completed))
        } catch is CancellationError {
            continuation.finish(); return
        } catch {
            continuation.yield(.init(bytesDownloaded: 0, totalBytes: nil, bytesPerSecond: 0,
                                     phase: .failed(String(describing: error))))
        }
        continuation.finish()
    }

    /// Unknown-length single stream — write sequentially until EOF; throttling still applies.
    private func streamWhole(url: URL, destination: URL, bytesPerSecond: Double, emitter: Emitter) async throws -> Int64 {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try? fm.removeItem(at: destination) }
        fm.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination); defer { try? handle.close() }

        var limiters: [RateLimiter] = []
        if let globalLimiter { limiters.append(globalLimiter) }
        if bytesPerSecond > 0 { limiters.append(RateLimiter(bytesPerSecond: bytesPerSecond)) }

        let (bytes, response) = try await session.bytes(for: URLRequest(url: url))
        guard let http = response as? HTTPURLResponse else { throw DownloadError.badResponse }
        guard (200...299).contains(http.statusCode) else { throw DownloadError.httpStatus(http.statusCode) }

        var done: Int64 = 0
        var buffer = Data(); buffer.reserveCapacity(256 * 1024)
        // Inline flush avoids Swift 6 sending-risk errors with nested async func capturing actor vars.
        @Sendable func flushBuffer(_ buf: inout Data, into h: FileHandle, limiters ls: [RateLimiter],
                                   emitter em: Emitter, done d: inout Int64) async throws {
            guard !buf.isEmpty else { return }
            try h.write(contentsOf: buf)
            let count = buf.count
            buf.removeAll(keepingCapacity: true)
            for l in ls { await l.throttle(count) }
            d += Int64(count)
            await em.record(Int64(count), total: nil)
        }
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 256 * 1024 {
                try Task.checkCancellation()
                try await flushBuffer(&buffer, into: handle, limiters: limiters, emitter: emitter, done: &done)
            }
        }
        try await flushBuffer(&buffer, into: handle, limiters: limiters, emitter: emitter, done: &done)
        return done
    }
}

/// True when a downloaded file already exists at exactly `bytes` on disk.
private func fileSize(_ url: URL) -> Int64? {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
    return (attrs[.size] as? NSNumber)?.int64Value
}

/// Sanity check that a saved segment set still tiles the whole file.
private func segmentsCover(_ segments: [SegmentState], _ total: Int64) -> Bool {
    segments.reduce(Int64(0)) { $0 + $1.length } == total
}

/// Serialises progress emission so bytesDownloaded is monotonic (no out-of-order yields).
private actor Emitter {
    private let continuation: AsyncStream<DownloadProgress>.Continuation
    private let start: TimeInterval
    private(set) var total: Int64 = 0
    /// Bytes already on disk when this run began (resume). Speed is measured on
    /// bytes fetched THIS run so a resume doesn't report a spike.
    private var seed: Int64 = 0
    init(continuation: AsyncStream<DownloadProgress>.Continuation, start: TimeInterval) {
        self.continuation = continuation; self.start = start
    }
    func seed(_ bytes: Int64) { seed = bytes; total = bytes }
    func record(_ delta: Int64, total totalBytes: Int64?) {
        total += delta
        let elapsed = max(0.001, nowSeconds() - start)
        // clamp: a 200-rewind emits a negative delta, which must not surface as
        // negative speed or negative bytes downloaded.
        let speed = max(0, Double(total - seed)) / elapsed
        continuation.yield(.init(bytesDownloaded: max(0, total), totalBytes: totalBytes,
                                 bytesPerSecond: speed, phase: .downloading))
    }
}
