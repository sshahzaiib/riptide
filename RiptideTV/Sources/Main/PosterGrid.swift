import SwiftUI

struct PosterGrid<Item: Identifiable, Card: View>: View {
    let items: [Item]
    @ViewBuilder let card: (Item) -> Card

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 40), count: 6), spacing: 40) {
                ForEach(items) { card($0) }
            }
            .padding(60)
        }
    }
}
