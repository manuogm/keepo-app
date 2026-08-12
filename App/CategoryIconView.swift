import KeepoCore
import SwiftUI

/// A category's icon+color, as a small round badge — the list-row
/// counterpart to `CategoriesView`'s square tiles. `nil` (a transfer, or a
/// row whose category isn't in the cached list yet) renders a neutral
/// placeholder rather than nothing, so row heights never jump.
struct CategoryIconView: View {
    let category: PublicSchema.CategoriesSelect?
    var diameter: CGFloat = 32

    var body: some View {
        Image(systemName: category?.icon ?? "questionmark")
            .font(.system(size: diameter * 0.45))
            .foregroundStyle(.white)
            .frame(width: diameter, height: diameter)
            .background(category.map { Color(hex: $0.color) } ?? Color.gray)
            .clipShape(Circle())
    }
}
