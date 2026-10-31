import SwiftUI
import StreamCore
import class StreamCore.LibraryItem

/// Everything a card can open. Equality/hash by id so it works as a nav value.
enum TitleRef: Hashable {
    case libraryMovie(LibraryItem)
    case libraryShow(ShowGroup)
    case media(SearchMedia)

    var id: String {
        switch self {
        case .libraryMovie(let i): "lm-\(i.itemKey)"
        case .libraryShow(let g): "ls-\(g.id)"
        case .media(let m): m.id
        }
    }
    static func == (a: TitleRef, b: TitleRef) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    /// A library file opens its movie page or its show's page.
    @MainActor static func forItem(_ item: LibraryItem) -> TitleRef {
        guard item.mediaKind == "episode" else { return .libraryMovie(item) }
        let group = item.tmdbID.flatMap { AppModels.library.showGroup(tmdbID: $0) }
            ?? ShowGroup(id: item.title.lowercased(), title: item.title,
                         posterPath: item.posterPath, episodes: [item])
        return .libraryShow(group)
    }

    /// A TMDB hit we already own becomes the library title (Play never needs addons).
    @MainActor var resolved: TitleRef {
        guard case .media(let m) = self else { return self }
        let lib = AppModels.library
        if m.isShow { return lib.showGroup(tmdbID: m.tmdbID).map(TitleRef.libraryShow) ?? self }
        return lib.items.first { $0.tmdbID == m.tmdbID && $0.mediaKind == "movie" }
            .map(TitleRef.libraryMovie) ?? self
    }

    var isShow: Bool {
        switch self {
        case .libraryMovie: false
        case .libraryShow: true
        case .media(let m): m.isShow
        }
    }
    var tmdbID: Int? {
        switch self {
        case .libraryMovie(let i): i.tmdbID
        case .libraryShow(let g): g.tmdbID
        case .media(let m): m.tmdbID
        }
    }
    var title: String {
        switch self {
        case .libraryMovie(let i): i.title.isEmpty ? i.filename : i.title
        case .libraryShow(let g): g.title
        case .media(let m): m.title
        }
    }
    var year: Int? {
        switch self {
        case .libraryMovie(let i): i.year
        case .libraryShow(let g): g.episodes.compactMap(\.year).first
        case .media(let m): m.year
        }
    }
    var overview: String {
        switch self {
        case .libraryMovie(let i): i.overview ?? ""
        case .libraryShow(let g): g.episodes.compactMap(\.overview).first ?? ""
        case .media(let m): m.overview
        }
    }
    var posterPath: String? {
        switch self {
        case .libraryMovie(let i): i.posterPath
        case .libraryShow(let g): g.posterPath
        case .media(let m): m.posterPath
        }
    }
}

extension View {
    /// Per-tab navigation stack that opens TitlePage for any TitleRef value.
    func titleStack() -> some View {
        NavigationStack { navigationDestination(for: TitleRef.self) { TitlePage(ref: $0) } }
    }
}
