import SwiftUI

/// One segment of a fill bar: a share of the whole, in a colour that means
/// something.
///
/// There is no "negative" segment. There used to be — an outlined, dashed one
/// for a credit card inside a currency's holdings — and it was the wrong
/// shape for the idea: a card *offsets* the holdings rather than being a
/// slice of them, so it had no honest length, and at a realistic magnitude it
/// rendered as a three-point dash too short to show a dash pattern at all.
/// Currency Exposure lists those accounts instead, with a red figure and no
/// share, which says the same thing without needing a key.
struct FillSegment: Identifiable, Equatable {
    let id: String
    let share: Double
    let color: Color
}

/// The dashboard's fill bar — horizontal or vertical, one segment or
/// several.
///
/// Shared because three widgets draw one and they must agree on the details
/// that make it readable: the track's weight, the corner, and what happens
/// when the segments don't reach the end (the remainder stays visible track,
/// never a stretched last segment).
struct WidgetFillBar: View {
    let segments: [FillSegment]
    var axis: Axis = .horizontal
    var thickness: CGFloat = 6
    /// Draws the track behind the fill. Off when several bars sit side by
    /// side as a chart, where a track behind each one reads as a grid.
    var showsTrack = true

    var body: some View {
        GeometryReader { proxy in
            let extent = axis == .horizontal ? proxy.size.width : proxy.size.height
            ZStack(alignment: axis == .horizontal ? .leading : .bottom) {
                if showsTrack {
                    Capsule().fill(Color.secondary.opacity(0.16))
                }
                stack(extent: extent)
            }
        }
        .frame(
            width: axis == .vertical ? thickness : nil,
            height: axis == .horizontal ? thickness : nil
        )
    }

    @ViewBuilder
    private func stack(extent: CGFloat) -> some View {
        let layout = axis == .horizontal
            ? AnyLayout(HStackLayout(spacing: 1))
            : AnyLayout(VStackLayout(spacing: 1))
        layout {
            if axis == .vertical { Spacer(minLength: 0) }
            ForEach(segments) { segment in
                Capsule().fill(segment.color)
                    .frame(
                        width: axis == .horizontal ? length(segment, extent: extent) : nil,
                        height: axis == .vertical ? length(segment, extent: extent) : nil
                    )
            }
            if axis == .horizontal { Spacer(minLength: 0) }
        }
    }

    /// Clamped into the track. The clamp is only visual — a ratio above 100%
    /// (leverage) still reads as its true number in the headline above.
    private func length(_ segment: FillSegment, extent: CGFloat) -> CGFloat {
        extent * min(max(segment.share, 0), 1)
    }
}

extension WidgetFillBar {
    /// The common case: one filled share in the neutral series colour.
    init(share: Double?, color: Color = WidgetPalette.neutral, axis: Axis = .horizontal, thickness: CGFloat = 6) {
        self.init(
            segments: [FillSegment(id: "fill", share: share ?? 0, color: color)],
            axis: axis,
            thickness: thickness
        )
    }
}
