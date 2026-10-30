import SwiftUI

struct PosterCard: View {
    let title: String
    let posterURL: URL?
    var progress: Double? = nil
    var wide = false
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: action) {
                AsyncImage(url: posterURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.12))
                        Text(title).font(.headline).multilineTextAlignment(.center)
                            .foregroundStyle(.secondary).padding()
                    }
                }
                .aspectRatio(wide ? 16 / 9 : 2 / 3, contentMode: .fill)
                .clipped()
                .overlay(alignment: .bottom) {
                    if wide, let progress {
                        GeometryReader { geo in
                            Rectangle().fill(.white.opacity(0.3)).overlay(alignment: .leading) {
                                Rectangle().fill(.red).frame(width: geo.size.width * min(max(progress, 0), 1))
                            }
                        }
                        .frame(height: 6)
                    }
                }
            }
            .buttonStyle(.card)
            Text(title).font(.callout.weight(.medium)).lineLimit(1)
        }
    }
}
