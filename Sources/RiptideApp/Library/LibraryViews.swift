import SwiftUI
import UniformTypeIdentifiers
import StreamCore
import class StreamCore.LibraryItem

enum SidebarSection: String, CaseIterable, Identifiable {
    case continueWatching = "Continue Watching"
    case movies = "Movies"
    case shows = "TV Shows"
    case files = "Other Files"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .continueWatching: "play.circle"
        case .movies: "film"
        case .shows: "tv"
        case .files: "doc"
        }
    }
}

struct LibraryRootView: View {
    @State private var model: LibraryModel
    @State private var selection: SidebarSection = .movies
    @State private var showSettings = false
    @State private var showAddTorrent = false
    @State private var addTorrentPrefill: String?
    @State private var path = NavigationPath()
    @State private var toast: String?
    @State private var droppedTorrentFile: URL?

    init(store: LibraryStore) {
        _model = State(initialValue: LibraryModel(store: store))
    }

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.icon).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            // Explicit stack, recreated on sidebar change (.id) — otherwise a
            // pushed detail view survives selection changes and the sidebar
            // appears dead.
            NavigationStack(path: $path) {
                detailView
                    .searchable(text: $model.searchText, placement: .toolbar)
                    .navigationDestination(for: String.self) { itemKey in
                        AddedItemDestination(itemKey: itemKey)
                    }
                    .onPasteCommand(of: [.plainText, .url]) { _ in
                        if let s = NSPasteboard.general.string(forType: .string),
                           s.hasPrefix("magnet:") {
                            addTorrentPrefill = s
                            showAddTorrent = true
                        }
                    }
                    .toolbar {
                        ToolbarItem {
                            Button(action: { addTorrentPrefill = nil; showAddTorrent = true }) {
                                Image(systemName: "plus")
                            }
                            .help("Add magnet or .torrent")
                        }
                        ToolbarItem {
                            Button(action: { Task { await model.refresh() } }) {
                                if model.refreshing { ProgressView().controlSize(.small) }
                                else { Image(systemName: "arrow.clockwise") }
                            }
                            .disabled(model.refreshing)
                        }
                        ToolbarItem {
                            Button(action: { showSettings = true }) {
                                Image(systemName: "gearshape")
                            }
                        }
                    }
            }
            .id(selection)
        }
        .sheet(isPresented: $showSettings, onDismiss: { Task { await model.refresh() } }) {
            SettingsView()
        }
        .sheet(isPresented: $showAddTorrent, onDismiss: { droppedTorrentFile = nil }) {
            AddTorrentSheet(prefill: addTorrentPrefill, torrentFile: droppedTorrentFile) { added in
                Task { await handleAdded(added) }
            }
        }
        .task {
            // Debug playback session: don't touch Keychain-backed settings.
            guard ProcessInfo.processInfo.environment["RIPTIDE_DEBUG_URL"] == nil else { return }
            if ProcessInfo.processInfo.environment["RIPTIDE_TRAKT_PROBE"] != nil {
                await TraktService.shared.probePlayback()
                return
            }
            if !AppSettings.shared.isConfigured { showSettings = true }
            else if model.items.isEmpty { await model.refresh() }
            // Populated library: no full RD refresh on launch, but watched
            // state should still flow in from Trakt.
            else { await TraktService.shared.pullSync(store: model.store) }
        }
        .alert("Real-Debrid authorization failed", isPresented: $model.needsAuth) {
            Button("Open Settings") { showSettings = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your Real-Debrid API token is missing or expired.")
        }
        .environment(model)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            if url.scheme == "magnet" {
                addTorrentPrefill = url.absoluteString
                showAddTorrent = true
                return true
            }
            if url.isFileURL, url.pathExtension.lowercased() == "torrent" {
                // Reuse the sheet: no prefill; submit the file directly after present.
                droppedTorrentFile = url
                showAddTorrent = true
                return true
            }
            return false
        }
        .onOpenURL { url in
            // magnet: scheme handler. Registration requires a packaged .app
            // (CFBundleURLTypes) — inert under the unbundled run.sh binary,
            // active once the app ships as a bundle.
            guard url.scheme == "magnet" else { return }
            addTorrentPrefill = url.absoluteString
            showAddTorrent = true
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .continueWatching: ContinueWatchingGrid()
        case .movies: MovieGrid()
        case .shows: ShowsList()
        case .files: FileList()
        }
    }

    private func handleAdded(_ added: TorrentAdder.Added) async {
        await model.refresh()
        switch added.outcome {
        case .ready, .alreadyInLibrary:
            if let item = model.firstItem(torrentID: added.torrentID) {
                selection = item.mediaKind == "episode" ? .shows
                    : (item.tmdbID != nil ? .movies : .files)
                path.append(item.itemKey)
            } else {
                showToast("Added — refresh again once Real-Debrid finishes.")
            }
        case .downloading:
            showToast("Added — downloading on Real-Debrid.")
        }
    }

    private func showToast(_ message: String) {
        withAnimation { toast = message }
        Task {
            try? await Task.sleep(for: .seconds(3))
            withAnimation { toast = nil }
        }
    }
}

private let posterColumns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 16)]

struct MovieGrid: View {
    @Environment(LibraryModel.self) private var model

    var body: some View {
        ScrollView {
            LazyVGrid(columns: posterColumns, spacing: 20) {
                ForEach(model.movies, id: \.itemKey) { item in
                    NavigationLink(destination: ItemDetailView(item: item)) {
                        PosterCard(title: item.title, subtitle: item.year.map(String.init),
                                   posterPath: item.posterPath)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .overlay {
            if model.movies.isEmpty {
                ContentUnavailableView("No movies yet",
                                       systemImage: "film",
                                       description: Text("Refresh to sync your Real-Debrid library."))
            }
        }
    }
}

struct ShowsList: View {
    @Environment(LibraryModel.self) private var model

    var body: some View {
        ScrollView {
            LazyVGrid(columns: posterColumns, spacing: 20) {
                ForEach(model.shows) { show in
                    NavigationLink(destination: ShowDetailView(show: show)) {
                        PosterCard(title: show.title,
                                   subtitle: "\(show.episodes.count) episode(s)",
                                   posterPath: show.posterPath)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .overlay {
            if model.shows.isEmpty {
                ContentUnavailableView("No TV shows yet", systemImage: "tv",
                                       description: Text("Refresh to sync your Real-Debrid library."))
            }
        }
    }
}

struct ContinueWatchingGrid: View {
    @Environment(LibraryModel.self) private var model

    var body: some View {
        ScrollView {
            LazyVGrid(columns: posterColumns, spacing: 20) {
                ForEach(model.continueWatching) { entry in
                    PlayableCard(item: entry.item,
                                 progress: entry.state.durationSeconds > 0
                                     ? entry.state.positionSeconds / entry.state.durationSeconds : 0)
                }
            }
            .padding()
        }
        .overlay {
            if model.continueWatching.isEmpty {
                ContentUnavailableView("Nothing in progress", systemImage: "play.circle",
                                       description: Text("Movies you start watching appear here."))
            }
        }
    }
}

struct FileList: View {
    @Environment(LibraryModel.self) private var model

    var body: some View {
        List(model.unmatched, id: \.itemKey) { item in
            PlayableFileRow(item: item)
        }
        .overlay {
            if model.unmatched.isEmpty {
                ContentUnavailableView("No unmatched files", systemImage: "doc",
                                       description: Text("Files TMDB can't identify appear here — still playable."))
            }
        }
    }
}

struct PosterCard: View {
    let title: String
    let subtitle: String?
    let posterPath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: posterPath.map { TMDB.imageURL(path: $0) }) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "film").font(.largeTitle).foregroundStyle(.secondary)
                }
            }
            .frame(height: 240)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(title).font(.callout.weight(.medium)).lineLimit(1)
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Card that plays directly on click (Continue Watching).
struct PlayableCard: View {
    @Environment(LibraryModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let item: LibraryItem
    let progress: Double
    @State private var busy = false

    var body: some View {
        Button(action: { Task { await play() } }) {
            VStack(alignment: .leading, spacing: 6) {
                PosterCard(title: item.title,
                           subtitle: item.season.map { "S\($0)E\(item.episode ?? 0)" },
                           posterPath: item.posterPath)
                ProgressView(value: progress).controlSize(.small)
            }
            .overlay { if busy { ProgressView() } }
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private func play() async {
        busy = true
        defer { busy = false }
        if let playItem = try? await model.playItem(for: item, autoResume: true) {
            openWindow(value: playItem)
        }
    }
}

/// Plain file row with a play button (unmatched items — spec's fallback card).
struct PlayableFileRow: View {
    @Environment(LibraryModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let item: LibraryItem
    @State private var busy = false

    var body: some View {
        HStack {
            Image(systemName: "doc.fill").foregroundStyle(.secondary)
            VStack(alignment: .leading) {
                Text(item.filename).lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: item.sizeBytes,
                                               countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: { Task { await play() } }) {
                if busy { ProgressView().controlSize(.small) }
                else { Image(systemName: "play.fill") }
            }
            .disabled(busy || item.link.isEmpty)
        }
        .padding(.vertical, 2)
    }

    private func play() async {
        busy = true
        defer { busy = false }
        if let playItem = try? await model.playItem(for: item) {
            openWindow(value: playItem)
        }
    }
}

/// Resolves an itemKey pushed after an add: movie → detail, episode → its show page.
struct AddedItemDestination: View {
    @Environment(LibraryModel.self) private var model
    let itemKey: String

    var body: some View {
        if let item = model.items.first(where: { $0.itemKey == itemKey }) {
            if item.mediaKind == "episode",
               let show = model.shows.first(where: { group in
                   group.episodes.contains { $0.itemKey == itemKey }
               }) {
                ShowDetailView(show: show)
            } else {
                ItemDetailView(item: item)
            }
        } else {
            ContentUnavailableView("Item not in library yet", systemImage: "clock")
        }
    }
}
