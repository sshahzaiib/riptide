import SwiftUI
import StreamCore

struct ContinueTab: View {
    let library: LibraryModel
    private let upNext = UpNextModel.shared
    @State private var loaded = false

    private var showUpNext: Bool { TraktService.shared.isConnected && !upNext.entries.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                if showUpNext {
                    PosterRow(title: "Up next", items: upNext.entries) { entry in
                        PosterCard(title: entry.media.title,
                                   posterURL: entry.media.posterPath.map { TMDB.imageURL(path: $0, width: 780) },
                                   progress: entry.item.progressPercent.map { $0 / 100 },
                                   wide: true, width: 400, subtitle: upNextSubtitle(entry), ref: .media(entry.media))
                    }
                }
                if !library.continueWatching.isEmpty {
                    PosterRow(title: "Continue watching", items: library.continueWatching) { entry in
                        PosterCard(title: entry.item.title.isEmpty ? entry.item.filename : entry.item.title,
                                   posterURL: entry.item.posterPath.map { TMDB.imageURL(path: $0, width: 780) },
                                   progress: entry.state.durationSeconds > 0
                                       ? entry.state.positionSeconds / entry.state.durationSeconds : 0,
                                   wide: true, width: 400, subtitle: resumeSubtitle(entry), ref: .forItem(entry.item))
                    }
                }
                if !showUpNext && library.continueWatching.isEmpty {
                    Text("Nothing to continue yet").font(.title3).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.top, 200)
                }
            }
            .padding(.vertical, 40)
        }
        .task {
            guard !loaded else { return }
            loaded = true
            if TraktService.shared.isConnected { await upNext.load() }
        }
    }

    private func upNextSubtitle(_ e: UpNextModel.Entry) -> String {
        var parts: [String] = []
        if let s = e.item.season, let n = e.item.number {
            parts.append("S\(s) E\(n)")
            if let t = e.item.episodeTitle, !t.isEmpty { parts.append(t) }
        }
        if let pct = e.item.progressPercent, pct > 0 { parts.append("\(Int(pct))% watched") }
        return parts.joined(separator: " · ")
    }

    private func resumeSubtitle(_ e: ContinueEntry) -> String {
        var parts: [String] = []
        if let s = e.item.season, let n = e.item.episode { parts.append("S\(s) E\(n)") }
        let pos = e.state.positionSeconds, dur = e.state.durationSeconds
        if dur > 0 {
            let m = Int(((dur - pos) / 60).rounded())
            parts.append(m >= 60 ? "\(m / 60) h \(m % 60) min left" : "\(max(m, 1)) min left")
        } else {
            let t = Int(pos)
            parts.append(String(format: "%d:%02d played", t / 60, t % 60))
        }
        return parts.joined(separator: " · ")
    }
}
