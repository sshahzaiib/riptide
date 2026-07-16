import Foundation

/// Intro/credits windows derived from chapter *shape*, not chapter names.
///
/// Names are unusable in practice: rips commonly carry no chapter title
/// metadata, and mpv then returns the formatted chapter time as
/// `chapter-list/N/title` (verified on a real library file — every title came
/// back as "00:01:54.114" and the like). So detection keys off layout instead:
/// a short chapter early in the file is the opening titles, and a short final
/// chapter is the end credits.
public struct ChapterMarkers: Equatable, Sendable {
    /// `[start, end)` of the opening titles.
    public let intro: Range<Double>?
    /// Position where the end credits begin.
    public let creditsStart: Double?

    public static let none = ChapterMarkers(intro: nil, creditsStart: nil)

    public init(intro: Range<Double>?, creditsStart: Double?) {
        self.intro = intro
        self.creditsStart = creditsStart
    }

    /// An intro starts within this many seconds of the file start.
    static let introSearchWindow = 360.0
    /// Plausible title-sequence length.
    static let introMin = 30.0
    static let introMax = 180.0
    /// Plausible end-credits length.
    static let creditsMax = 180.0

    /// - Parameters:
    ///   - chapterStarts: ascending chapter start times in seconds.
    ///   - duration: file duration in seconds; closes the final chapter.
    public static func detect(chapterStarts: [Double], duration: Double) -> ChapterMarkers {
        guard duration > 0, !chapterStarts.isEmpty else { return .none }
        let spans = Array(zip(chapterStarts, Array(chapterStarts.dropFirst()) + [duration]))

        // Shortest — not first — so a show that opens with a cold open before
        // the titles picks the titles. `min(by:)` only replaces on strictly
        // less, so ties resolve to the earliest span for free.
        // ponytail: a recap chapter (~40s) ahead of the titles would win on
        // "shortest". Prefer the span nearest a typical title length, or merge
        // contiguous short leading spans, if that ever shows up.
        let introIndex = spans.indices
            .filter { i in
                let (start, end) = spans[i]
                return start < introSearchWindow
                    && (end - start) >= introMin && (end - start) <= introMax
            }
            .min { (spans[$0].1 - spans[$0].0) < (spans[$1].1 - spans[$1].0) }

        // ponytail: a post-credits scene would make the final chapter the
        // credits marker instead of the actual credits. Bounded — the window is
        // still real file data, so the card just appears at the wrong span.
        let lastIndex = spans.count - 1
        let creditsStart: Double? = {
            guard lastIndex != introIndex else { return nil }   // degenerate 1–2 chapter file
            let (start, end) = spans[lastIndex]
            let length = end - start
            return length >= 0 && length <= creditsMax ? start : nil
        }()

        return ChapterMarkers(intro: introIndex.map { spans[$0].0..<spans[$0].1 },
                              creditsStart: creditsStart)
    }
}
