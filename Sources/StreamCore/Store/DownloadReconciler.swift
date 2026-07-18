import Foundation

public struct DownloadReconcilePlan: Equatable {
    public let requeue: [String]      // itemKeys of interrupted downloads to restart
    public let markMissing: [String]  // itemKeys completed but whose file is gone
    public init(requeue: [String], markMissing: [String]) {
        self.requeue = requeue
        self.markMissing = markMissing
    }
}

/// Pure startup reconciliation: interrupted downloads restart (MVP has no
/// partial resume); completed records whose file vanished are marked missing
/// so play-from-local never points at a dead path.
public enum DownloadReconciler {
    public static func plan(
        records: [(itemKey: String, state: DownloadState, localPath: String)],
        fileExists: (String) -> Bool
    ) -> DownloadReconcilePlan {
        var requeue: [String] = []
        var missing: [String] = []
        for r in records {
            switch r.state {
            case .downloading: requeue.append(r.itemKey)
            case .completed: if !fileExists(r.localPath) { missing.append(r.itemKey) }
            case .failed: break
            }
        }
        return DownloadReconcilePlan(requeue: requeue, markMissing: missing)
    }
}
