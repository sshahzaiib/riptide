import SwiftUI
import StreamCore

struct StreamPickerSheet: View {
    let request: StreamRequest

    var body: some View {
        Text("Streams for \(request.imdbID)")   // Task 9 replaces this
            .frame(width: 560, height: 480)
    }
}
