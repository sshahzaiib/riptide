import SwiftUI
import StreamCore

struct CastRow: View {
    let cast: [TMDBCastMember]

    var body: some View {
        if !cast.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Cast").font(.title3.bold())
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(cast, id: \.id) { member in
                            VStack(spacing: 6) {
                                AsyncImage(url: member.profilePath.map {
                                    TMDB.imageURL(path: $0, width: 185)
                                }) { image in
                                    image.resizable().aspectRatio(contentMode: .fill)
                                } placeholder: {
                                    ZStack {
                                        Circle().fill(.quaternary)
                                        Image(systemName: "person.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .frame(width: 72, height: 72)
                                .clipShape(Circle())

                                Text(member.name)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                if let character = member.character {
                                    Text(character)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .frame(width: 90)
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
    }
}
