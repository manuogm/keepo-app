import SwiftUI

/// A left-aligned row of chips that wraps onto as many lines as it needs.
///
/// A custom `Layout` rather than an `HStack` in a `ScrollView`, or a
/// `LazyVGrid`: a horizontal scroller hides tags off-screen with nothing
/// saying so (the count is exactly what the user wants to see at a glance),
/// and a grid forces every chip into an identical column width, which for
/// content as variable as "Coffee" vs "Kids' school run" leaves either huge
/// gaps or truncation.
///
/// Used by the category form's Category Tags section and by the transaction
/// form's chip row — the second call site is what makes it shared rather
/// than private to one of them.
struct TagFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let rows = rows(within: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var originY = bounds.minY
        for row in rows(within: bounds.width, subviews: subviews) {
            var originX = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: originX, y: originY + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                originX += size.width + spacing
            }
            originY += row.height + spacing
        }
    }

    /// One pass, greedy: a chip goes on the current line if it fits and on a
    /// new one if it doesn't. The first chip on a line is placed regardless
    /// of width — a single chip wider than the container has nowhere better
    /// to go, and starting a new line for it would loop forever.
    private func rows(within maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row(indices: [], width: 0, height: 0)

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty && needed > maxWidth {
                rows.append(current)
                current = Row(indices: [index], width: size.width, height: size.height)
            } else {
                current.indices.append(index)
                current.width = needed
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }

    private struct Row {
        var indices: [Int]
        var width: CGFloat
        var height: CGFloat
    }
}
