import Foundation

/// Split a byte count into `count` contiguous inclusive ranges; remainder to earliest.
public func planSegments(totalBytes: Int64, count: Int) -> [SegmentState] {
    precondition(totalBytes >= 0 && count >= 1)
    if totalBytes == 0 { return [SegmentState(index: 0, start: 0, end: -1)] }
    let n = Int64(min(Int64(count), totalBytes))
    let base = totalBytes / n, remainder = totalBytes % n
    var out: [SegmentState] = []; var cursor: Int64 = 0
    for i in 0..<n {
        let size = base + (i < remainder ? 1 : 0)
        out.append(SegmentState(index: Int(i), start: cursor, end: cursor + size - 1))
        cursor += size
    }
    return out
}
