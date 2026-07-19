import Foundation

public struct DownloadRequest: Sendable, Equatable {
    public let url: URL
    public let destination: URL
    public let connections: Int
    public let bytesPerSecond: Double   // per-download cap; 0 = unlimited
    public init(url: URL, destination: URL, connections: Int = 8, bytesPerSecond: Double = 0) {
        self.url = url; self.destination = destination
        self.connections = connections; self.bytesPerSecond = bytesPerSecond
    }
}

public struct QueueUpdate: Sendable, Equatable {
    public let id: UUID
    public let progress: DownloadProgress
    public init(id: UUID, progress: DownloadProgress) { self.id = id; self.progress = progress }
}

/// In-memory max-concurrent download queue. Runs up to `maxConcurrent` downloads
/// through a `DownloadRunning` engine; items beyond the limit wait. A `TimeWindow`
/// gates when new downloads may START (in-flight ones always finish); `startNow()`
/// overrides the window. Emits every per-item update on `events`.
public actor DownloadQueue {
    public nonisolated let events: AsyncStream<QueueUpdate>
    private nonisolated let continuation: AsyncStream<QueueUpdate>.Continuation

    private let runner: DownloadRunning
    private let maxConcurrent: Int
    private let window: TimeWindow?
    private let clock: @Sendable () -> Date
    private let calendar: Calendar
    private var startNowOverride = false

    private struct Pending { let id: UUID; let request: DownloadRequest }
    private struct Active { let token: Int; let task: Task<Void, Never> }
    private var waiting: [Pending] = []
    private var active: [UUID: Active] = [:]
    private var requests: [UUID: DownloadRequest] = [:]
    private var nextToken = 0

    public init(runner: DownloadRunning, maxConcurrent: Int = 4, window: TimeWindow? = nil,
                clock: @escaping @Sendable () -> Date = { Date() }, calendar: Calendar = .current) {
        self.runner = runner
        self.maxConcurrent = max(1, maxConcurrent)
        self.window = window
        self.clock = clock
        self.calendar = calendar
        (events, continuation) = AsyncStream.makeStream(of: QueueUpdate.self)
    }

    public init(maxConcurrent: Int = 4, globalBytesPerSecond: Double = 0,
                session: URLSession = DownloadEngine.makeSession(connections: 8)) {
        let limiter = globalBytesPerSecond > 0 ? RateLimiter(bytesPerSecond: globalBytesPerSecond) : nil
        self.init(runner: DownloadEngine(session: session, globalLimiter: limiter), maxConcurrent: maxConcurrent)
    }

    @discardableResult
    public func add(_ request: DownloadRequest) -> UUID {
        let id = UUID()
        waiting.append(Pending(id: id, request: request))
        requests[id] = request
        emit(id, .queued)
        pump()
        return id
    }

    deinit {
        for a in active.values { a.task.cancel() }   // don't leak in-flight downloads if the queue dies
        continuation.finish()
    }

    /// Re-evaluate the schedule (call on a minute timer). When the window is open, start any
    /// eligible waiting items. When it is closed, no NEW downloads start — but downloads already
    /// in flight run to completion (this layer restarts rather than resumes, so interrupting a
    /// near-done download would waste it; true pause/resume waits on Plan 5 persistence).
    public func tick() { pump() }

    public func cancel(_ id: UUID) {
        waiting.removeAll { $0.id == id }
        if let a = active[id] { a.task.cancel(); active[id] = nil }
        requests[id] = nil
        pump()
    }

    /// Ignore the time window and run the queue now; stays in effect until `resumeSchedule()`.
    public func startNow() { startNowOverride = true; pump() }

    /// Restore time-window gating after a `startNow()` (no-op if never overridden).
    public func resumeSchedule() { startNowOverride = false }

    private var isWindowOpen: Bool {
        if startNowOverride { return true }
        guard let window else { return true }
        return window.contains(TimeWindow.minuteOfDay(of: clock(), calendar: calendar))
    }

    // MARK: - internals

    private func pump() {
        guard isWindowOpen else { return }
        while active.count < maxConcurrent, !waiting.isEmpty {
            startItem(waiting.removeFirst())
        }
    }

    private func startItem(_ item: Pending) {
        let token = nextToken; nextToken += 1
        let r = item.request
        let stream = runner.start(url: r.url, destination: r.destination,
                                  connections: r.connections, bytesPerSecond: r.bytesPerSecond)
        let task = Task { [weak self] in
            for await p in stream {
                if Task.isCancelled { break }              // stop promptly on cancel
                await self?.forward(item.id, token: token, p)
            }
            await self?.itemFinished(item.id, token: token)
        }
        active[item.id] = Active(token: token, task: task)
    }

    private func forward(_ id: UUID, token: Int, _ p: DownloadProgress) {
        guard active[id]?.token == token else { return }   // stale attempt (cancelled) — drop
        continuation.yield(QueueUpdate(id: id, progress: p))
        switch p.phase {
        case .completed, .failed:                          // terminal — free the slot and start the next
            active[id] = nil
            requests[id] = nil
            pump()
        default:
            break
        }
    }

    // Safety net for a stream that ends WITHOUT a terminal phase (our own cancellation, or a
    // producer that just finish()es). Idempotent with `forward`'s terminal cleanup via the token guard.
    private func itemFinished(_ id: UUID, token: Int) {
        guard active[id]?.token == token else { return }   // already cleaned up / superseded — ignore
        active[id] = nil
        requests[id] = nil
        pump()
    }

    private func emit(_ id: UUID, _ phase: DownloadPhase) {
        continuation.yield(QueueUpdate(id: id,
            progress: DownloadProgress(bytesDownloaded: 0, totalBytes: nil, bytesPerSecond: 0, phase: phase)))
    }
}
