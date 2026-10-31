import SwiftUI
import StreamCore

struct TraktSignInView: View {
    let onDone: () -> Void
    @State private var code: TraktDeviceCode?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 28) {
            Text("Sign in to Trakt").font(.largeTitle.bold())
            if let code {
                Text("Go to \(code.verificationUrl) and enter this code")
                    .font(.title3).foregroundStyle(.secondary)
                Text(code.userCode)
                    .font(.system(size: 120, weight: .bold, design: .monospaced))
                    .kerning(12)
                ProgressView()
            } else if let error {
                Text(error).foregroundStyle(.red)
                Button("Retry") { Task { await request() } }
            } else {
                ProgressView()
            }
            Button("Skip", action: onDone)
            Text("Without Trakt, Continue Watching is forgotten whenever tvOS clears storage and never matches your Mac.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 900)
        }
        .padding(80)
        .task { await request() }
        .task(id: code?.deviceCode) {
            guard let code else { return }
            if await TraktService.shared.awaitAuthorization(code: code) { onDone() }
        }
    }

    private func request() async {
        error = nil
        do { code = try await TraktService.shared.requestDeviceCode() }
        catch { self.error = error.localizedDescription }
    }
}
