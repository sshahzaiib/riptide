import SwiftUI
import StreamCore

/// Heart menu for rating a movie or show on Trakt (10 down to 1).
/// Invisible unless Trakt is connected.
struct TraktRatingMenu: View {
    let media: TraktMedia
    @State private var rating: Int?

    var body: some View {
        if TraktService.shared.isConnected {
            Menu {
                ForEach((1...10).reversed(), id: \.self) { value in
                    Button {
                        rating = value
                        TraktService.shared.rate(media: media, rating: value)
                    } label: {
                        if rating == value {
                            Label("\(value)", systemImage: "checkmark")
                        } else {
                            Text("\(value)")
                        }
                    }
                }
            } label: {
                Label(rating.map { "\($0)/10" } ?? "Rate",
                      systemImage: rating != nil ? "heart.fill" : "heart")
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .fixedSize()
            .task { rating = await TraktService.shared.rating(for: media) }
        }
    }
}
