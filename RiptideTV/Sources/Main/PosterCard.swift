import SwiftUI

struct PosterCard: View {
    let title: String
    let posterURL: URL?
    var progress: Double? = nil
    var wide = false
    var width: CGFloat? = nil
    var subtitle: String? = nil
    let ref: TitleRef

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink(value: ref) {
                AsyncImage(url: posterURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.12))
                        Text(title).font(.headline).multilineTextAlignment(.center)
                            .foregroundStyle(.secondary).padding()
                    }
                }
                .modifier(ArtFrame(width: width, wide: wide))
                .clipped()
                .overlay(alignment: .bottom) {
                    if let progress {
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
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(width: width)
    }
}

private struct ArtFrame: ViewModifier {
    let width: CGFloat?
    let wide: Bool
    func body(content: Content) -> some View {
        if let width {
            content.frame(width: width, height: width * (wide ? 9 / 16 : 3 / 2))
        } else {
            content.aspectRatio(wide ? 16 / 9 : 2 / 3, contentMode: .fill)
        }
    }
}
