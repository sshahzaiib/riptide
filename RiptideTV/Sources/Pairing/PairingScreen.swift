import SwiftUI
import StreamCore

struct PairingScreen: View {
    let server: PairingServer
    let onContinue: () -> Void

    private var canContinue: Bool {
        ["rdToken", "tmdbToken"].allSatisfy { n in server.fields.first { $0.name == n }?.isSet == true }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 80) {
            VStack(spacing: 24) {
                if let url = server.url, let cg = QRCode.image(for: url.absoluteString) {
                    Image(decorative: cg, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 400, height: 400)
                        .padding(20)
                        .background(.white)
                    Text(url.absoluteString)
                        .font(.system(.callout, design: .monospaced))
                        .frame(maxWidth: 480)
                } else {
                    Text("Connect the Apple TV to your network")
                        .font(.title3).foregroundStyle(.secondary)
                        .frame(width: 440, height: 440)
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                Text("Set up from your phone or laptop").font(.title2.bold()).lineLimit(2)
                Text("Scan this code or open this address on any device on the same network.")
                    .foregroundStyle(.secondary)
                ForEach(server.fields, id: \.name) { f in
                    HStack(spacing: 16) {
                        Text(f.label).font(.headline)
                        if let r = f.result { Text(r).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Text(f.isSet ? "✓" : "✗ not set")
                            .font(.callout)
                            .foregroundStyle(f.isSet ? Color.green : Color.secondary)
                    }
                }
                Spacer()
                HStack {
                    Spacer()
                    Button("Continue", action: onContinue).disabled(!canContinue)
                }
            }
        }
        .padding(.horizontal, 80).padding(.vertical, 40)
        .onAppear { try? server.start() }
        .onDisappear { server.stop() }
    }
}
