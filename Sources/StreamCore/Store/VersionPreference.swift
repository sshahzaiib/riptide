// Sources/StreamCore/Store/VersionPreference.swift
import Foundation

/// Ranks duplicate files of the same movie/episode. Preference is computed,
/// never persisted: playing a version updates its WatchState, which makes it
/// the preferred one on the next read — zero schema change.
public enum VersionPreference {
    /// 2160p/4K > 1080p > 720p > 480p > unknown/garbage.
    static func qualityRank(_ quality: String?) -> Int {
        switch quality?.lowercased() {
        case "2160p", "4k": 0
        case "1080p": 1
        case "720p": 2
        case "480p": 3
        default: 4
        }
    }

    /// Order: most recently played → quality → stable input order.
    public static func ranked(items: [LibraryItem],
                              states: [String: WatchState]) -> [LibraryItem] {
        func sortKey(_ pair: (offset: Int, element: LibraryItem)) -> (Double, Int, Int) {
            let at = states[pair.element.itemKey]?.lastWatchedAt.timeIntervalSince1970 ?? 0
            // Whole-second precision: setWatched stamps every duplicate in a
            // loop microseconds apart; write order must not decide preference.
            // ponytail: a stamp loop crossing a second boundary can still
            // split the tie — harmless (both copies just got marked watched)
            // and self-healing (playback re-stamps every 5 s). Inject a shared
            // timestamp into setWatched if it ever matters.
            return (-at.rounded(.down), qualityRank(pair.element.quality), pair.offset)
        }
        return items.enumerated().sorted { sortKey($0) < sortKey($1) }.map(\.element)
    }

    public static func preferred(items: [LibraryItem],
                                 states: [String: WatchState]) -> LibraryItem? {
        ranked(items: items, states: states).first
    }
}
