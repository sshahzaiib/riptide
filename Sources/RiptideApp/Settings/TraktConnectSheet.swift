import SwiftUI
import StreamCore

/// Device-code flow: shows the short code, polls until trakt.tv approves.
struct TraktConnectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var code: TraktDeviceCode?
    @State private var failed = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Connect Trakt").font(.title2.bold())
            if failed {
                Label("Authorization failed or expired.", systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
                Button("Close") { dismiss() }
            } else if let code {
                Text("Enter this code at").foregroundStyle(.secondary)
                Link(code.verificationUrl,
                     destination: URL(string: code.verificationUrl)
                        ?? URL(string: "https://trakt.tv/activate")!)
                Text(code.userCode)
                    .font(.system(size: 34, weight: .bold, design: .monospaced))
                    .textSelection(.enabled)
                ProgressView().controlSize(.small)
                Text("Waiting for approval…").font(.caption).foregroundStyle(.secondary)
                Button("Cancel") { dismiss() }
            } else {
                ProgressView()
            }
        }
        .padding(32)
        .frame(width: 380)
        .task {
            do {
                let fetched = try await TraktService.shared.requestDeviceCode()
                code = fetched
                if await TraktService.shared.awaitAuthorization(code: fetched) {
                    dismiss()
                } else {
                    failed = true
                }
            } catch {
                failed = true
            }
        }
    }
}
