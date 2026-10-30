import Foundation
import Network
import Observation
import StreamCore

/// Tiny LAN HTTP server that serves the pairing form while the pairing screen
/// is visible. One listener per instance; `stop()` tears everything down.
@Observable @MainActor
final class PairingServer {
    private(set) var url: URL?
    private(set) var fields: [PairingFieldState] = []

    @ObservationIgnored private let apply: (PairingPayload) async -> [PairingFieldState]
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var connections: [ObjectIdentifier: NWConnection] = [:]
    @ObservationIgnored private var token = ""
    @ObservationIgnored private let queue = DispatchQueue(label: "riptide.pairing")
    private static let maxRequest = 64 * 1024

    /// apply receives each submitted payload and returns the current state of all seven fields.
    /// An empty payload must change nothing and just report state; the server calls it once on
    /// start() to populate the list.
    init(apply: @escaping (PairingPayload) async -> [PairingFieldState]) {
        self.apply = apply
    }

    func start() throws {
        guard listener == nil else { return }
        let l = try NWListener(using: .tcp)
        let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        token = String((0..<8).map { _ in chars.randomElement()! })
        l.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.listener === l else { return }
                if case .ready = state, let port = l.port?.rawValue {
                    if let ip = Self.lanIPv4() {
                        self.url = URL(string: "http://\(ip):\(port)/\(self.token)")
                    }
                } else if case .failed = state {
                    self.stop()
                }
            }
        }
        l.newConnectionHandler = { [weak self] conn in
            Task { @MainActor in self?.accept(conn) }
        }
        listener = l
        l.start(queue: queue)
        Task { @MainActor in
            let initial = await apply(PairingPayload())
            if listener === l, fields.isEmpty { fields = initial }
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        token = ""
        url = nil
    }

    private func accept(_ conn: NWConnection) {
        guard listener != nil else { conn.cancel(); return }
        connections[ObjectIdentifier(conn)] = conn
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func finish(_ conn: NWConnection, status: Int, html: String) {
        conn.send(content: PairingHTTP.response(status: status, html: html),
                  completion: .contentProcessed { [weak self] _ in
            conn.cancel()
            Task { @MainActor in self?.connections[ObjectIdentifier(conn)] = nil }
        })
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, self.connections[ObjectIdentifier(conn)] != nil else { return }
                var buf = buffer
                if let data { buf.append(data) }
                if let req = PairingHTTP.parse(buf) {
                    await self.handle(req, on: conn)
                } else if buf.count > Self.maxRequest {
                    self.finish(conn, status: 400, html: "<p>Request too large</p>")
                } else if error != nil || isComplete {
                    conn.cancel()
                    self.connections[ObjectIdentifier(conn)] = nil
                } else {
                    self.receive(conn, buffer: buf)
                }
            }
        }
    }

    private func handle(_ req: PairingRequest, on conn: NWConnection) async {
        let tok = token
        guard !tok.isEmpty, req.path == "/\(tok)", req.method == "GET" || req.method == "POST" else {
            return finish(conn, status: 404, html: "<p>Not found</p>")
        }
        if req.method == "POST" {
            let payload: PairingPayload
            if req.contentType?.contains("application/json") == true {
                guard let p = try? JSONDecoder().decode(PairingPayload.self, from: Data(req.body.utf8)) else {
                    return finish(conn, status: 400, html: "<p>Bad JSON</p>")
                }
                payload = p
            } else {
                payload = PairingPayload.fromForm(req.body)
            }
            let states = await apply(payload)
            guard listener != nil else { return conn.cancel() }
            fields = states
        }
        finish(conn, status: 200, html: PairingPage.html(fields: fields, token: tok))
    }

    /// First UP, non-loopback IPv4 interface, preferring `en*`.
    nonisolated static func lanIPv4() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var found: [(name: String, ip: String)] = []
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                  Int32(ifa.ifa_flags) & IFF_UP != 0, Int32(ifa.ifa_flags) & IFF_LOOPBACK == 0
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            found.append((String(cString: ifa.ifa_name), String(cString: host)))
        }
        return (found.first { $0.name.hasPrefix("en") } ?? found.first)?.ip
    }
}
