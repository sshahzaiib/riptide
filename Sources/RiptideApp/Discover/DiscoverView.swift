// Sources/RiptideApp/Discover/DiscoverView.swift
import SwiftUI
import StreamCore

struct DiscoverView: View {
    @Environment(LibraryModel.self) private var library
    private let model = DiscoverModel.shared

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(model.orderedShelves) { shelf in
                    shelfView(shelf)
                }
            }
            .padding()
        }
        .navigationTitle("Discover")
        .toolbar {
            Button {
                model.load(force: true)
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r")
        }
        .task { model.load() }
    }

    @ViewBuilder
    private func shelfView(_ id: DiscoverModel.ShelfID) -> some View {
        let shelf = model.shelves[id] ?? .init()
        VStack(alignment: .leading, spacing: 8) {
            Text(id.rawValue).font(.title3.bold())
            switch shelf.state {
            case .idle, .loading:
                skeletonRow
            case .failed:
                HStack {
                    Text("Couldn't load this shelf.")
                        .foregroundStyle(.secondary)
                    Button("Retry") { model.retry(id) }
                }
            case .loaded:
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(shelf.items) { media in
                            NavigationLink(destination: DiscoverDestination(media: media, library: library)) {
                                card(for: media)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func card(for media: SearchMedia) -> some View {
        PosterCard(title: media.title,
                   subtitle: media.year.map(String.init),
                   posterPath: media.posterPath)
            .frame(width: 160)
            .overlay(alignment: .topTrailing) {
                if library.hasLibraryEntry(tmdbID: media.tmdbID, isShow: media.isShow) {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .green)
                        .padding(6)
                }
            }
    }

    private var skeletonRow: some View {
        HStack(spacing: 12) {
            ForEach(0..<6, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
                    .frame(width: 160, height: 240)
            }
        }
    }
}

struct DiscoverDestination: View {
    let media: SearchMedia
    let library: LibraryModel

    var body: some View {
        if media.isShow {
            if library.hasLibraryEntry(tmdbID: media.tmdbID, isShow: true),
               let group = library.shows.first(where: { $0.tmdbID == media.tmdbID }) {
                ShowDetailView(show: group)
            } else {
                SearchDetailView(media: media)
            }
        } else {
            if library.hasLibraryEntry(tmdbID: media.tmdbID, isShow: false),
               let item = library.libraryItem(tmdbID: media.tmdbID, season: nil, episode: nil) {
                ItemDetailView(item: item)
            } else {
                SearchDetailView(media: media)
            }
        }
    }
}
