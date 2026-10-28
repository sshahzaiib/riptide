import SwiftUI
import UniformTypeIdentifiers
import StreamCore
import class StreamCore.LibraryItem

enum SidebarSection: String, CaseIterable, Identifiable {
    case discover = "Discover"
    case watchlist = "Watchlist"
    case continueWatching = "Continue Watching"
    case history = "History"
    case movies = "Movies"
    case shows = "TV Shows"
    case files = "Other Files"
    case downloads = "Transfers"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .discover: "safari"
        case .watchlist: "bookmark"
        case .continueWatching: "play.circle"
        case .history: "clock.arrow.circlepath"
        case .movies: "film"
        case .shows: "tv"
        case .files: "doc"
        case .downloads: "arrow.left.arrow.right.circle"
        }
    }
}

struct LibraryRootView: View {
    @State private var model: LibraryModel
    @State private var downloads: DownloadsModel
    @State private var localDownloads: LocalDownloadManager
    @State private var showSettings = false
    @State private var showAddTorrent = false
    @State private var addTorrentPrefill: String?
    @State private var path = NavigationPath()
    @State private var suppressPathReset = false
    @State private var toastTask: Task<Void, Never>?
    @State private var toast: String?
    @State private var droppedTorrentFile: URL?

    init(store: LibraryStore) {
        let model = LibraryModel(store: store)
        _model = State(initialValue: model)
        _downloads = State(initialValue: DownloadsModel(library: model))
        _localDownloads = State(initialValue: LocalDownloadManager(store: store))
    }

    private var visibleSections: [SidebarSection] {
        SidebarSection.allCases.filter {
            $0 != .watchlist || TraktService.shared.isConnected
        }
    }

    var body: some View {
        NavigationSplitView {
            List(visibleSections, selection: $model.sidebarSelection) { section in
                Label(section.rawValue, systemImage: section.icon)
                    .badge(section == .downloads ? downloads.activeCount : 0)
                    .tag(section)
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
                            droppedTorrentFile = nil
                            addTorrentPrefill = s
                            showAddTorrent = true
                        }
                    }
                    .toolbar {
                        ToolbarItem {
                            Button(action: { addTorrentPrefill = nil; droppedTorrentFile = nil; showAddTorrent = true }) {
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
                            DownloadsToolbarButton().environment(localDownloads)
                        }
                        ToolbarItem {
                            Button(action: { showSettings = true }) {
                                Image(systemName: "gearshape")
                            }
                        }
                    }
            }
            .id(model.sidebarSelection)
        }
        .sheet(isPresented: $showSettings, onDismiss: { Task { await model.refresh() } }) {
            SettingsView(onScanFolder: { localDownloads.importExternalFiles() })
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
        .task { localDownloads.start() }
        .alert("Real-Debrid authorization failed", isPresented: $model.needsAuth) {
            Button("Open Settings") { showSettings = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your Real-Debrid API token is missing or expired.")
        }
        .safeAreaInset(edge: .bottom) {
            if let message = model.errorMessage {
                HStack {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Dismiss") { model.errorMessage = nil }
                        .buttonStyle(.borderless).controlSize(.small)
                }
                .padding(8)
                .background(.bar)
            }
        }
        .confirmationDialog("Delete from debrid?", isPresented: Binding(
            get: { model.pendingDelete != nil }, set: { if !$0 { model.pendingDelete = nil } }),
            presenting: model.pendingDelete) { items in
            Button("Delete", role: .destructive) { Task { for i in items { await model.delete(i) } } }
        } message: { items in
            let torrents = Set(items.map(\.torrentID))
            let others = model.items.filter { torrents.contains($0.torrentID) }.count - items.count
            Text("Removes the whole torrent from your debrid account" + (others > 0 ? " and \(others) other files." : "."))
        }
        .environment(model)
        .environment(downloads)
        .environment(localDownloads)
        .onChange(of: downloads.toastMessage) {
            guard let message = downloads.toastMessage else { return }
            showToast(message)
            downloads.toastMessage = nil
        }
        // ponytail: dropped support for dragging raw magnet TEXT (not a link) — needs a custom multi-representation Transferable to safely coexist with the URL dropDestination; ⌘V paste and dragging an actual magnet: link both already work.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            if url.scheme == "magnet" {
                droppedTorrentFile = nil
                addTorrentPrefill = url.absoluteString
                showAddTorrent = true
                return true
            }
            if url.isFileURL, url.pathExtension.lowercased() == "torrent" {
                // Reuse the sheet: no prefill; submit the file directly after present.
                addTorrentPrefill = nil
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
            droppedTorrentFile = nil
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
        .onChange(of: model.sidebarSelection) {
            if suppressPathReset {
                suppressPathReset = false
            } else {
                path = NavigationPath()
            }
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch model.sidebarSelection {
        case .discover: DiscoverView()
        case .watchlist: WatchlistView()
        case .continueWatching: ContinueWatchingGrid()
        case .history: HistoryGrid()
        case .movies: MovieGrid()
        case .shows: ShowsList()
        case .files: FileList()
        case .downloads: DownloadsView()
        }
    }

    private func handleAdded(_ added: TorrentAdder.Added) async {
        await model.refresh()
        switch added.outcome {
        case .ready, .alreadyInLibrary:
            if let item = model.firstItem(torrentID: added.torrentID) {
                let newSelection: SidebarSection = item.mediaKind == "episode" ? .shows
                    : (item.tmdbID != nil ? .movies : .files)
                if model.sidebarSelection != newSelection { suppressPathReset = true }
                model.sidebarSelection = newSelection
                path = NavigationPath([item.itemKey])
            } else {
                showToast("Added — refresh again once Real-Debrid finishes.")
            }
        case .downloading:
            // Uncached add via the sheet, same as the stream picker's
            // registerUncached path — the poller must pick up this transfer
            // or its ready notification (and library refresh) never fires.
            downloads.kick()
            showToast("Added — downloading on Real-Debrid.")
        }
    }

    private func showToast(_ message: String) {
        toastTask?.cancel()
        withAnimation { toast = message }
        toastTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation { toast = nil }
        }
    }
}

private let posterColumns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 16)]

struct MovieGrid: View {
    @Environment(LibraryModel.self) private var model
    @Environment(LocalDownloadManager.self) private var downloads

    /// One entry per tmdbID, copies preference-ranked (first = preferred).
    private var groups: [[LibraryItem]] {
        let states = Dictionary(((try? model.store.allWatchStates()) ?? []).map { ($0.itemKey, $0) },
                                uniquingKeysWith: { first, _ in first })
        var order: [Int] = []
        let byID = Dictionary(grouping: model.movies) { $0.tmdbID! }
        for m in model.movies where !order.contains(m.tmdbID!) { order.append(m.tmdbID!) }
        return order.map { VersionPreference.ranked(items: byID[$0]!, states: states) }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: posterColumns, spacing: 20) {
                ForEach(groups, id: \.first!.itemKey) { copies in
                    let item = copies[0]
                    NavigationLink(destination: ItemDetailView(item: item)) {
                        PosterCard(title: item.title,
                                   subtitle: [item.year.map(String.init),
                                              copies.count > 1 ? "\(copies.count) versions" : nil]
                                       .compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
                                   posterPath: item.posterPath,
                                   downloaded: downloads.isDownloaded(item.itemKey))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        ForEach(copies, id: \.itemKey) { v in
                            Button("Delete · \(versionLabel(v, isPreferred: false))", role: .destructive) {
                                model.requestDelete([v])
                            }
                        }
                        if copies.count > 1 {
                            Button("Delete All Versions", role: .destructive) { model.requestDelete(copies) }
                        }
                    }
                }
            }
            .padding()

            if !model.searchText.isEmpty {
                GlobalSearchSection(kind: .movies)
            }
        }
        .overlay {
            if model.movies.isEmpty && model.searchText.isEmpty {
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

            if !model.searchText.isEmpty {
                GlobalSearchSection(kind: .shows)
            }
        }
        .overlay {
            if model.shows.isEmpty && model.searchText.isEmpty {
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

struct HistoryGrid: View {
    @Environment(LibraryModel.self) private var model
    @State private var streamRequest: StreamRequest?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: posterColumns, spacing: 20) {
                ForEach(model.history, id: \.key) { entry in
                    HistoryCard(entry: entry, streamRequest: $streamRequest)
                }
            }
            .padding()
        }
        .overlay {
            if model.history.isEmpty && model.searchText.isEmpty {
                ContentUnavailableView("Nothing watched yet", systemImage: "clock.arrow.circlepath",
                                       description: Text("Everything you play appears here."))
            }
        }
        .sheet(item: $streamRequest) { StreamPickerSheet(request: $0) }
    }
}

struct HistoryCard: View {
    @Environment(LibraryModel.self) private var model
    let entry: HistoryEntry
    @Binding var streamRequest: StreamRequest?

    private var isEpisode: Bool { entry.mediaKind == "episode" }

    private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
            PosterCard(title: entry.title,
                       subtitle: isEpisode ? "S\(entry.season ?? 0)E\(entry.episode ?? 0)"
                                           : entry.year.map(String.init),
                       posterPath: entry.posterPath)
            HStack(spacing: 4) {
                ProgressView(value: entry.finished ? 1 : entry.progress).controlSize(.small)
                if entry.finished {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
        }
    }

    var body: some View {
        Group {
            if isEpisode, let id = entry.tmdbID, let show = model.showGroup(tmdbID: id) {
                NavigationLink(destination: ShowDetailView(show: show)) { card }
            } else if !isEpisode, let id = entry.tmdbID,
                      let item = model.libraryItem(tmdbID: id, season: nil, episode: nil) {
                NavigationLink(destination: ItemDetailView(item: item)) { card }
            } else if let id = entry.tmdbID {
                Button { Task { await findStreams(tmdbID: id) } } label: { card }
            } else {
                card
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Remove from History", role: .destructive) { model.removeHistory(entry) }
        }
    }

    private func findStreams(tmdbID: Int) async {
        let token = AppSettings.shared.tmdbToken
        guard !token.isEmpty else { return }
        let tmdb = TMDBClient(bearerToken: token, cache: .shared)
        // ponytail: fetch failure leaves the card inert, no error UI.
        let ids = isEpisode ? try? await tmdb.externalIDs(showID: tmdbID)
                            : try? await tmdb.externalIDs(movieID: tmdbID)
        guard let imdbID = ids?.imdbID else { return }
        streamRequest = StreamRequest(type: isEpisode ? .series : .movie, imdbID: imdbID,
                                      title: entry.title, season: entry.season,
                                      episode: entry.episode, tmdbID: tmdbID)
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
    var downloaded: Bool = false

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
            .overlay(alignment: .topTrailing) {
                if downloaded {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.white, .blue)
                        .padding(6)
                }
            }

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
                HStack(spacing: 6) {
                    Text(item.filename).lineLimit(1)
                    ServiceBadge(service: item.service)
                }
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

/// "RD" / "AD" source tag. Only rendered for non-RD items until a second
/// service is the norm — an all-RD library doesn't need per-file noise.
struct ServiceBadge: View {
    let service: String
    var body: some View {
        if service != "rd" {
            Text(service.uppercased())
                .font(.caption2.bold())
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
