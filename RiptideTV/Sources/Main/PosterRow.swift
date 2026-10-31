import SwiftUI

struct PosterRow<Item: Identifiable, Card: View>: View {
    let title: String
    let items: [Item]
    @ViewBuilder let card: (Item) -> Card

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title).font(.title2.bold()).padding(.horizontal, 60)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 40) {
                    ForEach(items) { card($0) }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 20)
            }
        }
        .focusSection()
    }
}
