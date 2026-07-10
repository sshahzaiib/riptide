# Add Magnets / Torrent Files Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Paste a magnet link or drop a `.torrent` file into Riptide and have it land in Real-Debrid and the library without opening a browser (issue #6).

**Architecture:** StreamCore gains three small `RealDebridClient` endpoints (`addTorrentFile`, `deleteTorrent`, plus a raw-body request path) and a `TorrentAdder` orchestrator (add → auto-select video files → outcome), tested with the existing `MockURLProtocol` pattern. RiptideApp gains one `AddTorrentSheet` that all entry points (toolbar +, drag-drop, ⌘V, magnet: URLs) funnel into, plus post-add navigation to the new item.

**Tech Stack:** Swift / SwiftUI (macOS), swift-testing = XCTest, no new dependencies.

## Global Constraints

- Branch: `feat/add-torrents` (never commit to main).
- No new package dependencies.
- Commit messages: conventional style, **no Co-Authored-By trailers**.
- Tests: `swift test` from repo root (`/Users/shahzaib/Documents/dev/riptide`); 51 tests pass today, all must keep passing.
- Spec: `docs/superpowers/specs/2026-07-10-add-torrents-design.md`.
- Manual runs use `./scripts/run.sh`, never `swift run`.
- UI layer gets no tests (spec: "UI stays thin").

---

### Task 1: RD client — raw-body requests, `addTorrentFile`, `deleteTorrent`

**Files:**
- Modify: `Sources/StreamCore/RealDebrid/RealDebridClient.swift` (`send` at line 47, endpoints after line 125)
- Test: `Tests/StreamCoreTests/TorrentAdderTests.swift` (create)

**Interfaces:**
- Consumes: existing `send`, `decode`, `AddMagnetResult`, `MockURLProtocol` (+ its `URLRequest.bodyData` helper and `URLSession.mocked()`).
- Produces: `public func addTorrentFile(_ torrent: Data) async throws -> AddMagnetResult`, `public func deleteTorrent(_ id: String) async throws`, and internally `send(_:_:query:form:rawBody:)` where `rawBody: (data: Data, contentType: String)? = nil`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/StreamCoreTests/TorrentAdderTests.swift`:

```swift
import XCTest
@testable import StreamCore

final class TorrentAdderTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.setHandler(nil)
        super.tearDown()
    }

    private func client() -> RealDebridClient {
        RealDebridClient(token: "tok", session: .mocked(),
                         config: .init(pollInterval: 0.001, pollTimeout: 1),
                         sleep: { _ in })
    }

    // MARK: Endpoints

    func testAddTorrentFilePUTsRawBody() async throws {
        nonisolated(unsafe) var captured: (method: String?, contentType: String?,
                                           body: Data?, path: String?)
        MockURLProtocol.setHandler { req in
            captured = (req.httpMethod, req.value(forHTTPHeaderField: "Content-Type"),
                        req.bodyData, req.url?.path)
            return .json(#"{"id":"TID","uri":"https://real-debrid.com/torrents/TID"}"#,
                         status: 201)
        }
        let bytes = Data([0x64, 0x38, 0x3a])   // "d8:" bencode prefix
        let result = try await client().addTorrentFile(bytes)
        XCTAssertEqual(result.id, "TID")
        XCTAssertEqual(captured.method, "PUT")
        XCTAssertEqual(captured.contentType, "application/x-bittorrent")
        XCTAssertEqual(captured.body, bytes)
        XCTAssertEqual(captured.path, "/rest/1.0/torrents/addTorrent")
    }

    func testDeleteTorrentSendsDELETE() async throws {
        nonisolated(unsafe) var captured: (method: String?, path: String?)
        MockURLProtocol.setHandler { req in
            captured = (req.httpMethod, req.url?.path)
            return .init(status: 204)
        }
        try await client().deleteTorrent("TID")
        XCTAssertEqual(captured.method, "DELETE")
        XCTAssertEqual(captured.path, "/rest/1.0/torrents/delete/TID")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TorrentAdderTests 2>&1 | tail -5`
Expected: compile error — `addTorrentFile`/`deleteTorrent` don't exist.

- [ ] **Step 3: Implement**

In `Sources/StreamCore/RealDebrid/RealDebridClient.swift`, extend `send`'s signature (line 47):

```swift
    func send(_ method: String, _ path: String,
              query: [String: String]? = nil,
              form: [String: String]? = nil,
              rawBody: (data: Data, contentType: String)? = nil) async throws -> Data {
```

and after the existing `if let form { ... }` block inside it, add:

```swift
            if let rawBody {
                request.setValue(rawBody.contentType, forHTTPHeaderField: "Content-Type")
                request.httpBody = rawBody.data
            }
```

Then add the endpoints right after `addMagnet` (line 117):

```swift
    /// `PUT /torrents/addTorrent` with the raw `.torrent` bytes as the body.
    public func addTorrentFile(_ torrent: Data) async throws -> AddMagnetResult {
        let data = try await send("PUT", "torrents/addTorrent",
                                  rawBody: (torrent, "application/x-bittorrent"))
        return try decode(AddMagnetResult.self, from: data)
    }

    public func deleteTorrent(_ id: String) async throws {
        _ = try await send("DELETE", "torrents/delete/\(id)")
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TorrentAdderTests 2>&1 | tail -5`
Expected: 2 tests pass. Then `swift test 2>&1 | tail -3` — full suite (53) passes.

- [ ] **Step 5: Commit**

```bash
git add Sources/StreamCore/RealDebrid/RealDebridClient.swift Tests/StreamCoreTests/TorrentAdderTests.swift
git commit -m "feat(rd): addTorrentFile + deleteTorrent endpoints"
```

---

### Task 2: Models prep — `hash` on `TorrentListItem`, public video-extension list

**Files:**
- Modify: `Sources/StreamCore/RealDebrid/RealDebridModels.swift:88-104` (`TorrentListItem`)
- Modify: `Sources/StreamCore/Parse/ReleaseNameParser.swift:22-23` (`videoExtensions`)
- Test: `Tests/StreamCoreTests/TorrentAdderTests.swift` (extend)

**Interfaces:**
- Produces: `TorrentListItem.hash: String?` (new field, default `nil` in the memberwise init so existing callers/fixtures compile), `ReleaseNameParser.videoExtensions: Set<String>` becomes `public`.

- [ ] **Step 1: Write the failing test**

Add to `TorrentAdderTests`:

```swift
    func testTorrentListItemDecodesHash() throws {
        let json = #"{"id":"T1","filename":"x.mkv","hash":"ABCDEF0123","bytes":1,"progress":100,"status":"downloaded","added":"2026-01-01T00:00:00.000Z","links":[]}"#
        let item = try JSONDecoder().decode(TorrentListItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.hash, "ABCDEF0123")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter testTorrentListItemDecodesHash 2>&1 | tail -5`
Expected: compile error — `TorrentListItem` has no member `hash`.

- [ ] **Step 3: Implement**

In `RealDebridModels.swift`, change `TorrentListItem` to:

```swift
/// One entry from `GET /torrents`. `ended` is present only for finished torrents.
public struct TorrentListItem: Sendable, Equatable, Decodable {
    public let id: String
    public let filename: String
    public let hash: String?           // infohash (lowercase/uppercase hex as RD sends it)
    public let bytes: Int64
    public let progress: Double
    public let status: String
    public let added: String           // raw ISO-8601
    public let links: [String]
    public let ended: String?

    public init(id: String, filename: String, bytes: Int64, progress: Double,
                status: String, added: String, links: [String], ended: String?,
                hash: String? = nil) {
        self.id = id; self.filename = filename; self.bytes = bytes
        self.progress = progress; self.status = status; self.added = added
        self.links = links; self.ended = ended; self.hash = hash
    }
}
```

In `ReleaseNameParser.swift` line 22, change `private static let videoExtensions` to `public static let videoExtensions` (same value).

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test 2>&1 | tail -3`
Expected: full suite (54) passes — including existing `RealDebridListTests` fixtures without `hash`.

- [ ] **Step 5: Commit**

```bash
git add Sources/StreamCore/RealDebrid/RealDebridModels.swift Sources/StreamCore/Parse/ReleaseNameParser.swift Tests/StreamCoreTests/TorrentAdderTests.swift
git commit -m "feat(rd): decode torrent hash; expose video extension list"
```

---

### Task 3: `TorrentAdder` orchestrator

**Files:**
- Create: `Sources/StreamCore/RealDebrid/TorrentAdder.swift`
- Test: `Tests/StreamCoreTests/TorrentAdderTests.swift` (extend)

**Interfaces:**
- Consumes: `RealDebridClient` (`addMagnet`, `addTorrentFile`, `deleteTorrent`, `selectFiles`, `torrentInfo`, `allTorrents`, `pollUntil` — all same-module), `ReleaseNameParser.videoExtensions`, `TorrentListItem.hash`.
- Produces (used by the app layer in Tasks 4–6):

```swift
public struct TorrentAdder: Sendable {
    public enum Outcome: Sendable, Equatable {
        case alreadyInLibrary(torrentID: String)
        case ready(torrentID: String)
        case downloading(torrentID: String)
    }
    public enum AddSource: Sendable { case magnet(String); case file(Data) }
    public struct Added: Sendable, Equatable {
        public let outcome: Outcome
        public let torrentID: String
        public let files: [TorrentFile]       // all files RD listed
        public let selectedFileIDs: [Int]
    }
    public init(rd: RealDebridClient)
    public func add(_ source: AddSource) async throws -> Added
    public func reselect(source: AddSource, torrentID: String, fileIDs: [Int]) async throws -> Added
    static func infohash(fromMagnet: String) -> String?      // internal, tested
    static func videoFiles(in: [TorrentFile]) -> [TorrentFile] // internal, tested
}
```

- [ ] **Step 1: Write the failing tests**

Add to `TorrentAdderTests`:

```swift
    // MARK: TorrentAdder

    /// Scripted RD backend: magnet/file add → waiting_files_selection with
    /// `files`, selection captured, post-select status configurable.
    private func scriptedHandler(files: String, postSelectStatus: String,
                                 existingTorrents: String = "[]",
                                 record: @escaping @Sendable (String, String?) -> Void)
        -> (@Sendable (URLRequest) -> MockURLProtocol.Stub) {
        nonisolated(unsafe) var selected = false
        return { req in
            let path = req.url!.path
            record(path, req.bodyData.flatMap { String(data: $0, encoding: .utf8) })
            switch true {
            case path.hasSuffix("/torrents") && req.httpMethod == "GET":
                return .json(existingTorrents)
            case path.hasSuffix("/torrents/addMagnet"),
                 path.hasSuffix("/torrents/addTorrent"):
                return .json(#"{"id":"TID","uri":"u"}"#, status: 201)
            case path.contains("/torrents/selectFiles/"):
                selected = true
                return .init(status: 204)
            case path.contains("/torrents/delete/"):
                return .init(status: 204)
            case path.contains("/torrents/info/"):
                let status = selected ? postSelectStatus : "waiting_files_selection"
                return .json(#"{"id":"TID","filename":"pack","bytes":9,"progress":0,"status":"\#(status)","files":\#(files),"links":[]}"#)
            default:
                return .init(status: 404)
            }
        }
    }

    private let mixedPack = #"""
    [{"id":1,"path":"/pack/S01E01.mkv","bytes":900,"selected":0},
     {"id":2,"path":"/pack/Sample/sample.mkv","bytes":10,"selected":0},
     {"id":3,"path":"/pack/info.nfo","bytes":1,"selected":0},
     {"id":4,"path":"/pack/S01E02.mp4","bytes":900,"selected":0}]
    """#

    func testAddSelectsOnlyVideoFiles() async throws {
        nonisolated(unsafe) var selectBody: String?
        MockURLProtocol.setHandler(scriptedHandler(files: mixedPack,
                                                   postSelectStatus: "downloaded") { path, body in
            if path.contains("/selectFiles/") { selectBody = body }
        })
        let added = try await TorrentAdder(rd: client())
            .add(.magnet("magnet:?xt=urn:btih:cafebabe&dn=pack"))
        XCTAssertEqual(selectBody, "files=1%2C4")   // formEncode percent-encodes the comma
        XCTAssertEqual(added.outcome, .ready(torrentID: "TID"))
        XCTAssertEqual(added.selectedFileIDs, [1, 4])
        XCTAssertEqual(added.files.count, 4)
    }

    func testAddAllJunkFallsBackToSelectAll() async throws {
        nonisolated(unsafe) var selectBody: String?
        let junk = #"[{"id":1,"path":"/a.nfo","bytes":1,"selected":0},{"id":2,"path":"/b.txt","bytes":1,"selected":0}]"#
        MockURLProtocol.setHandler(scriptedHandler(files: junk,
                                                   postSelectStatus: "downloaded") { path, body in
            if path.contains("/selectFiles/") { selectBody = body }
        })
        let added = try await TorrentAdder(rd: client())
            .add(.magnet("magnet:?xt=urn:btih:cafebabe"))
        XCTAssertEqual(selectBody, "files=1%2C2")
        XCTAssertEqual(added.selectedFileIDs, [1, 2])
    }

    func testAddUncachedReportsDownloading() async throws {
        MockURLProtocol.setHandler(scriptedHandler(files: mixedPack,
                                                   postSelectStatus: "queued") { _, _ in })
        let added = try await TorrentAdder(rd: client())
            .add(.magnet("magnet:?xt=urn:btih:cafebabe"))
        XCTAssertEqual(added.outcome, .downloading(torrentID: "TID"))
    }

    func testAddDedupesByInfohash() async throws {
        nonisolated(unsafe) var addCalled = false
        let existing = #"[{"id":"OLD","filename":"x","hash":"CAFEBABE","bytes":1,"progress":100,"status":"downloaded","added":"2026-01-01T00:00:00.000Z","links":[]}]"#
        MockURLProtocol.setHandler(scriptedHandler(files: "[]", postSelectStatus: "downloaded",
                                                   existingTorrents: existing) { path, _ in
            if path.hasSuffix("/addMagnet") { addCalled = true }
        })
        let added = try await TorrentAdder(rd: client())
            .add(.magnet("magnet:?xt=urn:btih:cafebabe&dn=x"))
        XCTAssertEqual(added.outcome, .alreadyInLibrary(torrentID: "OLD"))
        XCTAssertFalse(addCalled)
    }

    func testTorrentFileAddSkipsDedupe() async throws {
        nonisolated(unsafe) var listedTorrents = false
        MockURLProtocol.setHandler(scriptedHandler(files: mixedPack,
                                                   postSelectStatus: "downloaded") { path, _ in
            if path.hasSuffix("/torrents") { listedTorrents = true }
        })
        _ = try await TorrentAdder(rd: client()).add(.file(Data([0x64])))
        XCTAssertFalse(listedTorrents)
    }

    func testReselectDeletesAndReAdds() async throws {
        nonisolated(unsafe) var calls: [String] = []
        nonisolated(unsafe) var selectBody: String?
        MockURLProtocol.setHandler(scriptedHandler(files: mixedPack,
                                                   postSelectStatus: "downloaded") { path, body in
            calls.append(path)
            if path.contains("/selectFiles/") { selectBody = body }
        })
        let added = try await TorrentAdder(rd: client())
            .reselect(source: .magnet("magnet:?xt=urn:btih:cafebabe"),
                      torrentID: "STALE", fileIDs: [1])
        XCTAssertTrue(calls.contains("/rest/1.0/torrents/delete/STALE"))
        XCTAssertTrue(calls.contains("/rest/1.0/torrents/addMagnet"))
        XCTAssertEqual(selectBody, "files=1")
        XCTAssertEqual(added.selectedFileIDs, [1])
    }

    func testInfohashParsing() {
        XCTAssertEqual(TorrentAdder.infohash(fromMagnet:
            "magnet:?xt=urn:btih:CAFEBABE123&dn=Some.Show"), "cafebabe123")
        XCTAssertNil(TorrentAdder.infohash(fromMagnet: "https://example.com/not-a-magnet"))
        XCTAssertNil(TorrentAdder.infohash(fromMagnet: "magnet:?dn=no-xt"))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TorrentAdderTests 2>&1 | tail -5`
Expected: compile error — `TorrentAdder` doesn't exist.

- [ ] **Step 3: Implement**

Create `Sources/StreamCore/RealDebrid/TorrentAdder.swift`:

```swift
import Foundation

/// Orchestrates adding a magnet/.torrent to Real-Debrid: dedupe by infohash,
/// add, auto-select video files, report whether the result is streamable now.
public struct TorrentAdder: Sendable {
    public enum Outcome: Sendable, Equatable {
        case alreadyInLibrary(torrentID: String)
        case ready(torrentID: String)        // RD status "downloaded"
        case downloading(torrentID: String)  // queued / downloading / …
    }

    public enum AddSource: Sendable {
        case magnet(String)
        case file(Data)
    }

    public struct Added: Sendable, Equatable {
        public let outcome: Outcome
        public let torrentID: String
        public let files: [TorrentFile]       // all files RD listed
        public let selectedFileIDs: [Int]
    }

    let rd: RealDebridClient

    public init(rd: RealDebridClient) { self.rd = rd }

    public func add(_ source: AddSource) async throws -> Added {
        switch source {
        case .magnet(let magnet):
            // Dedupe: same infohash already in the account → don't re-add.
            if let hash = Self.infohash(fromMagnet: magnet),
               let existing = try await rd.allTorrents()
                   .first(where: { $0.hash?.lowercased() == hash }) {
                return Added(outcome: .alreadyInLibrary(torrentID: existing.id),
                             torrentID: existing.id, files: [], selectedFileIDs: [])
            }
            let result = try await rd.addMagnet(magnet)
            return try await finishAdd(id: result.id)
        case .file(let data):
            // ponytail: no pre-add dedupe for .torrent files — hashing the
            // bencoded info dict isn't worth it; RD tolerates duplicates.
            let result = try await rd.addTorrentFile(data)
            return try await finishAdd(id: result.id)
        }
    }

    /// RD rejects selectFiles on an already-selected torrent
    /// (action_already_done), so editing = delete + re-add + select.
    public func reselect(source: AddSource, torrentID: String,
                         fileIDs: [Int]) async throws -> Added {
        try await rd.deleteTorrent(torrentID)
        let result: AddMagnetResult
        switch source {
        case .magnet(let magnet): result = try await rd.addMagnet(magnet)
        case .file(let data): result = try await rd.addTorrentFile(data)
        }
        return try await finishAdd(id: result.id, fileIDs: fileIDs)
    }

    /// Wait for RD to list files, select (explicit ids, else video files,
    /// else all), then map the post-selection status to an outcome.
    private func finishAdd(id: String, fileIDs: [Int]? = nil) async throws -> Added {
        let info = try await rd.pollUntil(id) {
            $0.status == "waiting_files_selection" || $0.status == "downloaded"
        }
        var selectedIDs = info.files.filter { $0.selected == 1 }.map(\.id)
        if info.status == "waiting_files_selection" {
            let chosen: [Int]
            if let fileIDs {
                chosen = fileIDs
            } else {
                let videos = Self.videoFiles(in: info.files)
                chosen = (videos.isEmpty ? info.files : videos).map(\.id)
            }
            try await rd.selectFiles(torrentID: id,
                                     files: chosen.map(String.init).joined(separator: ","))
            selectedIDs = chosen
        }
        let after = try await rd.torrentInfo(id)
        let outcome: Outcome = after.status == "downloaded"
            ? .ready(torrentID: id) : .downloading(torrentID: id)
        return Added(outcome: outcome, torrentID: id,
                     files: info.files, selectedFileIDs: selectedIDs)
    }

    /// Lowercased infohash from a magnet's `xt=urn:btih:` param, nil otherwise.
    static func infohash(fromMagnet magnet: String) -> String? {
        guard let comps = URLComponents(string: magnet), comps.scheme == "magnet"
        else { return nil }
        for item in comps.queryItems ?? [] where item.name == "xt" {
            if let value = item.value, value.lowercased().hasPrefix("urn:btih:") {
                return String(value.dropFirst("urn:btih:".count)).lowercased()
            }
        }
        return nil
    }

    /// Real video files: known extension, not a sample.
    static func videoFiles(in files: [TorrentFile]) -> [TorrentFile] {
        files.filter { file in
            let ext = (file.path as NSString).pathExtension.lowercased()
            return ReleaseNameParser.videoExtensions.contains(ext)
                && !file.path.lowercased().contains("sample")
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test 2>&1 | tail -3`
Expected: full suite (61) passes.

- [ ] **Step 5: Commit**

```bash
git add Sources/StreamCore/RealDebrid/TorrentAdder.swift Tests/StreamCoreTests/TorrentAdderTests.swift
git commit -m "feat(rd): TorrentAdder — add/dedupe/auto-select orchestration"
```

---

### Task 4: `AddTorrentSheet` + toolbar entry point

**Files:**
- Create: `Sources/RiptideApp/Library/AddTorrentSheet.swift` (model + sheet in one file)
- Modify: `Sources/RiptideApp/Library/LibraryViews.swift` (toolbar at lines 43-56, root state at 22-24)

**Interfaces:**
- Consumes: `TorrentAdder` (Task 3), `AppSettings.shared.rdToken`, `LibraryModel.refresh()` (environment).
- Produces: `struct AddTorrentSheet: View` with `init(prefill: String?, onAdded: @escaping (TorrentAdder.Added) -> Void)`; `@Observable final class TorrentAddModel` (same file) with `phase`, `magnetText`, `submitMagnet()`, `submit(fileURL:)`, `lastAdded`, `source`. Task 6 adds the edit-files sheet to this same file.

- [ ] **Step 1: Implement the model**

Create `Sources/RiptideApp/Library/AddTorrentSheet.swift`:

```swift
import SwiftUI
import UniformTypeIdentifiers
import StreamCore

/// State machine for one add flow. UI-thin: all RD logic lives in TorrentAdder.
@Observable
@MainActor
final class TorrentAddModel {
    enum Phase: Equatable {
        case input
        case adding
        case done
        case error(String)
    }

    var phase: Phase = .input
    var magnetText = ""
    private(set) var lastAdded: TorrentAdder.Added?
    private(set) var source: TorrentAdder.AddSource?

    var magnetIsValid: Bool {
        magnetText.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("magnet:")
    }

    func submitMagnet() async {
        let magnet = magnetText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard magnet.hasPrefix("magnet:") else {
            phase = .error("Not a magnet link.")
            return
        }
        await run(.magnet(magnet))
    }

    func submit(fileURL: URL) async {
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: fileURL) else {
            phase = .error("Could not read \(fileURL.lastPathComponent).")
            return
        }
        await run(.file(data))
    }

    func reselect(fileIDs: [Int]) async {
        guard let source, let lastAdded else { return }
        phase = .adding
        do {
            let adder = TorrentAdder(rd: RealDebridClient(token: AppSettings.shared.rdToken))
            self.lastAdded = try await adder.reselect(source: source,
                                                      torrentID: lastAdded.torrentID,
                                                      fileIDs: fileIDs)
            phase = .done
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    private func run(_ addSource: TorrentAdder.AddSource) async {
        source = addSource
        phase = .adding
        do {
            let adder = TorrentAdder(rd: RealDebridClient(token: AppSettings.shared.rdToken))
            lastAdded = try await adder.add(addSource)
            phase = .done
        } catch {
            phase = .error(error.localizedDescription)
        }
    }
}

/// One sheet for every entry point (toolbar +, drop, paste, magnet: URL).
/// Pass `prefill` to open with a magnet and auto-submit.
struct AddTorrentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model = TorrentAddModel()
    @State private var showFilePicker = false
    let prefill: String?
    let onAdded: (TorrentAdder.Added) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Torrent").font(.headline)
            content
        }
        .padding(20)
        .frame(width: 440)
        .fileImporter(isPresented: $showFilePicker,
                      allowedContentTypes: [UTType(filenameExtension: "torrent")
                                            ?? .data]) { result in
            if case .success(let url) = result {
                Task { await model.submit(fileURL: url) }
            }
        }
        .task {
            if let prefill {
                model.magnetText = prefill
                await model.submitMagnet()
            } else if let clip = NSPasteboard.general.string(forType: .string),
                      clip.hasPrefix("magnet:") {
                model.magnetText = clip
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .input:
            TextField("magnet:?xt=urn:btih:…", text: $model.magnetText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await model.submitMagnet() } }
            HStack {
                Button("Choose .torrent…") { showFilePicker = true }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { Task { await model.submitMagnet() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.magnetIsValid)
            }
        case .adding:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Adding to Real-Debrid…").foregroundStyle(.secondary)
            }
        case .done:
            doneView
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Try Again") { model.phase = .input }
            }
        }
    }

    @ViewBuilder
    private var doneView: some View {
        if let added = model.lastAdded {
            switch added.outcome {
            case .alreadyInLibrary:
                Label("Already in your library.", systemImage: "checkmark.circle")
            case .ready, .downloading:
                Label("Selected \(added.selectedFileIDs.count) video file(s).",
                      systemImage: "checkmark.circle")
                if case .downloading = added.outcome {
                    Text("Real-Debrid is downloading it — it appears in the library once ready.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                // Task 6 replaces this stub with the edit-files sheet trigger.
                Spacer()
                Button("Done") {
                    onAdded(added)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}
```

- [ ] **Step 2: Wire the toolbar button**

In `LibraryViews.swift`, add state to `LibraryRootView` (after line 24):

```swift
    @State private var showAddTorrent = false
    @State private var addTorrentPrefill: String?
```

Add a toolbar item before the refresh button (inside the `.toolbar { }` at line 43):

```swift
                        ToolbarItem {
                            Button(action: { addTorrentPrefill = nil; showAddTorrent = true }) {
                                Image(systemName: "plus")
                            }
                            .help("Add magnet or .torrent")
                        }
```

Add the sheet after the settings `.sheet` (line 62):

```swift
        .sheet(isPresented: $showAddTorrent) {
            AddTorrentSheet(prefill: addTorrentPrefill) { added in
                Task { await handleAdded(added) }
            }
        }
```

And a minimal handler in `LibraryRootView` (below `detailView`; Task 5 extends it with navigation):

```swift
    private func handleAdded(_ added: TorrentAdder.Added) async {
        await model.refresh()
    }
```

`StreamCore` is already imported.

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!` — zero warnings from new code.

- [ ] **Step 4: Commit**

```bash
git add Sources/RiptideApp/Library/AddTorrentSheet.swift Sources/RiptideApp/Library/LibraryViews.swift
git commit -m "feat(app): AddTorrentSheet + toolbar entry"
```

---

### Task 5: Remaining entry points + post-add navigation + toast

**Files:**
- Modify: `Sources/RiptideApp/Library/LibraryViews.swift` (root view)
- Modify: `Sources/RiptideApp/Library/LibraryModel.swift` (lookup helper)

**Interfaces:**
- Consumes: `AddTorrentSheet` (Task 4), `TorrentAdder.Added/Outcome` (Task 3), `ShowDetailView(show: ShowGroup)` and `ItemDetailView(item: LibraryItem)` (existing).
- Produces: `LibraryModel.firstItem(torrentID:) -> LibraryItem?`; `LibraryRootView` gains `@State path = NavigationPath()` and `.navigationDestination(for: String.self)` where the `String` is an `itemKey`.

- [ ] **Step 1: Add the lookup helper**

In `LibraryModel.swift`, after `playItem(for:autoResume:)`:

```swift
    /// First library item belonging to a torrent (itemKeys are "torrentID#fileIndex").
    func firstItem(torrentID: String) -> LibraryItem? {
        items.first { $0.itemKey.hasPrefix("\(torrentID)#") }
    }
```

- [ ] **Step 2: Programmatic navigation + toast + entry points**

In `LibraryViews.swift`:

1. Add state to `LibraryRootView`:

```swift
    @State private var path = NavigationPath()
    @State private var toast: String?
```

2. Change `NavigationStack {` (line 40) to `NavigationStack(path: $path) {` and add below `.searchable(...)`:

```swift
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
```

(`import AppKit` is unnecessary — `NSPasteboard` comes via SwiftUI's AppKit re-export; add `import AppKit` only if the build complains. `UniformTypeIdentifiers`'s `.plainText`/`.url` need `import UniformTypeIdentifiers` at the top of `LibraryViews.swift`.)

3. On the `NavigationSplitView` (after `.environment(model)`), add drop + magnet-URL support and the toast overlay:

```swift
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
```

4. Add `@State private var droppedTorrentFile: URL?` to `LibraryRootView`, and extend `AddTorrentSheet` with an optional `torrentFile: URL?` init parameter that, when set, calls `await model.submit(fileURL:)` from `.task` instead of the prefill path:

In `AddTorrentSheet`, add the stored property and change `.task`:

```swift
    let prefill: String?
    var torrentFile: URL? = nil
    let onAdded: (TorrentAdder.Added) -> Void
```

```swift
        .task {
            if let torrentFile {
                await model.submit(fileURL: torrentFile)
            } else if let prefill {
                model.magnetText = prefill
                await model.submitMagnet()
            } else if let clip = NSPasteboard.general.string(forType: .string),
                      clip.hasPrefix("magnet:") {
                model.magnetText = clip
            }
        }
```

Update the sheet presentation in `LibraryRootView` to pass it and clear it on dismiss:

```swift
        .sheet(isPresented: $showAddTorrent, onDismiss: { droppedTorrentFile = nil }) {
            AddTorrentSheet(prefill: addTorrentPrefill, torrentFile: droppedTorrentFile) { added in
                Task { await handleAdded(added) }
            }
        }
```

5. Replace `handleAdded` with the full version:

```swift
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
```

6. Add the destination resolver at the bottom of `LibraryViews.swift`:

```swift
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
```

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 4: Manual smoke test**

Run: `./scripts/run.sh` then: toolbar + opens the sheet; with a magnet link on the clipboard the field pre-fills; ⌘V in the library opens the sheet auto-submitted. (Full E2E with a real magnet happens in the final verification.)

- [ ] **Step 5: Commit**

```bash
git add Sources/RiptideApp/Library/LibraryViews.swift Sources/RiptideApp/Library/LibraryModel.swift Sources/RiptideApp/Library/AddTorrentSheet.swift
git commit -m "feat(app): drop/paste/magnet-URL entry points + post-add navigation"
```

---

### Task 6: Edit-files checklist sheet

**Files:**
- Modify: `Sources/RiptideApp/Library/AddTorrentSheet.swift`

**Interfaces:**
- Consumes: `TorrentAddModel.reselect(fileIDs:)`, `TorrentAdder.Added.files/selectedFileIDs` (Task 3/4).
- Produces: `EditFilesSheet` (private to the file), reachable from the done state of `AddTorrentSheet`.

- [ ] **Step 1: Implement**

In `AddTorrentSheet.swift`, add state to `AddTorrentSheet`:

```swift
    @State private var showEditFiles = false
```

In `doneView`, replace the `HStack` (the one with the Task 6 stub comment) with:

```swift
            HStack {
                if !added.files.isEmpty {
                    Button("Edit Files…") { showEditFiles = true }
                }
                Spacer()
                Button("Done") {
                    onAdded(added)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
```

Add the sheet modifier next to `.fileImporter`:

```swift
        .sheet(isPresented: $showEditFiles) {
            if let added = model.lastAdded {
                EditFilesSheet(files: added.files,
                               selected: Set(added.selectedFileIDs)) { ids in
                    Task { await model.reselect(fileIDs: Array(ids).sorted()) }
                }
            }
        }
```

Add at the bottom of the file:

```swift
/// Checklist over a torrent's files; confirming re-adds the torrent with
/// the chosen selection (RD can't change selection in place).
private struct EditFilesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let files: [TorrentFile]
    @State var selected: Set<Int>
    let onConfirm: (Set<Int>) -> Void

    init(files: [TorrentFile], selected: Set<Int>, onConfirm: @escaping (Set<Int>) -> Void) {
        self.files = files
        _selected = State(initialValue: selected)
        self.onConfirm = onConfirm
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select Files").font(.headline)
            List(files, id: \.id) { file in
                Toggle(isOn: Binding(
                    get: { selected.contains(file.id) },
                    set: { on in if on { selected.insert(file.id) } else { selected.remove(file.id) } }
                )) {
                    HStack {
                        Text((file.path as NSString).lastPathComponent).lineLimit(1)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: file.bytes,
                                                       countStyle: .file))
                            .foregroundStyle(.secondary).font(.caption)
                    }
                }
            }
            .frame(minHeight: 200)
            Text("Changing the selection re-adds the torrent on Real-Debrid.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    onConfirm(selected)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 3: Run full test suite**

Run: `swift test 2>&1 | tail -3`
Expected: 61 tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/RiptideApp/Library/AddTorrentSheet.swift
git commit -m "feat(app): edit-files checklist (delete + re-add reselection)"
```

---

### Final verification

- [ ] `swift test` — full suite green.
- [ ] Live E2E via `./scripts/run.sh`: add a real magnet (cached), confirm auto-selection count, library refresh, navigation to the item; drop a `.torrent`; ⌘V a magnet. User confirms before PR.
- [ ] PR to main via `gh pr create` (no co-author trailer), referencing `Closes #6`.
