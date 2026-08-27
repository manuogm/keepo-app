import KeepoCore
import SwiftUI

/// The one card every dashboard widget draws itself into. Cohesion on this
/// screen is not a styling preference — five widgets showing five unrelated
/// kinds of information only read as one dashboard if the surface, the
/// corner, the padding, and the header are literally the same view rather
/// than five approximations of the same idea.
///
/// A widget supplies a title, an explainer, and its body. Everything else — fill,
/// radius, insets, header typography, how the header sits above the content —
/// is decided here and nowhere else.
/// Constants shared by the chrome and by anything that has to match its
/// shape (a drag preview, a drop highlight). A plain enum rather than a
/// static on `WidgetChrome` itself, which is generic — `WidgetChrome<EmptyView>
/// .cornerRadius` at a call site that doesn't otherwise care about the
/// content type is noise.
enum WidgetStyle {
    static let cornerRadius: CGFloat = 22
    /// Every gap on this dashboard is a multiple of four points, and these
    /// constants are where that starts. The card's inset is 16 — the same
    /// step the grid's own 12pt gutter is drawn from — so the distance from
    /// a title to the card's edge is a number that appears elsewhere in the
    /// layout rather than a value that happened to look right.
    static let padding: CGFloat = 16
    /// The smallest a control on this dashboard may be, per Apple's HIG.
    /// Applied as a *hit* area rather than as visible furniture — a 44pt
    /// capsule around every W/M/Y segment would swamp a widget header — so
    /// the control keeps its drawn size and grows its `contentShape`.
    static let minimumTarget: CGFloat = 44
    /// The headline figure's size — **one number per state, for every
    /// widget**.
    ///
    /// It used to be a per-widget argument, and the six of them had drifted
    /// to 36, 34, 30 and 28: Net Worth's figure was two steps bigger than
    /// the FX rate sitting beside it, which made the dashboard read as
    /// several designs rather than one. The figure is the thing the eye
    /// lands on first in every tile, so it is the last thing that should
    /// vary between them.
    ///
    /// Expanded is smaller on purpose. The chart becomes the subject when a
    /// widget opens and the figure becomes its caption — that is a change of
    /// role, which every widget makes at the same moment, not a per-widget
    /// size.
    static let metric: CGFloat = 32
    static let metricExpanded: CGFloat = 28
}

extension View {
    /// Grows a control's touch area to `size` **without** growing its
    /// layout.
    ///
    /// The distinction is the whole point. `.frame(minHeight: 44)` also
    /// works, and is what this replaces — but it made every W/M/Y segment
    /// 44pt tall in layout terms, which is what forced the widget header
    /// to be 44pt tall, which is what pushed each widget's title and
    /// headline down when it expanded. An overlay is not laid out by the
    /// parent, so the header stays the height the design wants and the
    /// finger still gets the area HIG asks for.
    func hitTarget(_ size: CGFloat = WidgetStyle.minimumTarget) -> some View {
        contentShape(Rectangle())
            .overlay {
                Color.clear
                    .frame(minWidth: size, minHeight: size)
                    .contentShape(Rectangle())
            }
    }
}

struct WidgetChrome<Content: View>: View {
    let title: String
    /// The explainer behind the header's ⓘ. `nil` hides the button
    /// entirely, which is how a collapsed tile stays a figure and nothing
    /// else — there is no room on a 2×1 for a control that explains rather
    /// than does, and a user who wants the explanation has already opened
    /// the widget.
    var guide: WidgetGuide?
    /// Trailing header accessory, for the one thing a widget legitimately
    /// needs beside its own title (Cashflow's period filter). Widgets that
    /// don't need it pass nothing.
    var accessory: (() -> AnyView)?
    /// Expand/collapse. Applied to the whole card as a tap gesture rather
    /// than by wrapping it in a `Button`: an expanded widget has its own
    /// controls inside (Net Worth's range filter, Cashflow's series), and a
    /// `Button` nested in a `Button` is a coin flip about which one fires.
    /// A parent tap gesture reliably yields to an inner `Button`.
    var onTap: (() -> Void)?
    @ViewBuilder var content: () -> Content

    @State private var isShowingGuide = false
    /// The title's own height, which is the header's height — see `header`.
    @State private var titleHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(WidgetStyle.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: WidgetStyle.cornerRadius, style: .continuous)
        )
        // Nothing may draw outside the card. The tile's frame is a fixed size
        // handed down by the grid, but the background is only *painted* at
        // that size — content that overflows it (a tile whose text grew under
        // a large Dynamic Type setting) kept drawing straight through the
        // gutter, so the 12pt gap the grid computes correctly still looked
        // smaller around the shortest tile. This makes the card's bounds the
        // tile's bounds, so grid spacing can never depend on what a widget
        // happens to contain.
        .clipShape(RoundedRectangle(cornerRadius: WidgetStyle.cornerRadius, style: .continuous))
        // The tile is one object, so it lifts as one during a drag — without
        // this, a drag preview snapshots the full-bleed cell instead of the
        // rounded card the user can see.
        .contentShape(.dragPreview, RoundedRectangle(cornerRadius: WidgetStyle.cornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: WidgetStyle.cornerRadius, style: .continuous))
        .onTapGesture { onTap?() }
        .sheet(isPresented: $isShowingGuide) {
            if let guide {
                WidgetGuideSheet(title: title, guide: guide)
            }
        }
    }

    /// Title, optional ⓘ, optional accessory.
    ///
    /// **The header is exactly as tall as its title**, in both states, and
    /// that one rule settles two problems that pull in opposite directions.
    ///
    /// Left to size itself, the row grew to fit its tallest child — so
    /// expanding a widget, which puts the timeframe filter up here, pushed
    /// the title down and everything under it with it. Pinned instead to a
    /// constant tall enough for the filter, the title stopped moving but sat
    /// vertically centred in a row taller than itself, which put visible
    /// dead space above it: the gap over the title read as half again the
    /// card's padding, while the gap beside it was the padding exactly.
    ///
    /// Measuring the title is what gives both. The height is the title's, so
    /// the first line of the card sits the same distance from the top edge
    /// as it does from the leading one; and it is the *title's*, so it is
    /// the same number whether or not there is a filter beside it. The
    /// filter is taller than the row and simply overflows it — centred, into
    /// the card's own top padding above and into the header/content gap
    /// below, both of which are empty.
    ///
    /// It still sits in the `HStack` rather than in an overlay, so it
    /// reserves its width and a long title is squeezed by it rather than
    /// running underneath it.
    ///
    /// No glyph beside the title any more. It was the same size as the
    /// words next to it and repeated what they already said, so it read as
    /// decoration on a surface that has none to spare; dropping it is what
    /// buys the ⓘ its place without the header getting busier.
    private var header: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { titleHeight = $0 }
            if guide != nil { infoButton }
            Spacer(minLength: 4)
            accessory?()
        }
        .foregroundStyle(Color.secondary)
        // `nil` for the first frame, before the title has been measured —
        // the row is briefly its natural height rather than collapsed to
        // nothing.
        .frame(height: titleHeight > 0 ? titleHeight : nil)
    }

    private var infoButton: some View {
        Button {
            isShowingGuide = true
        } label: {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(Color.secondary)
                .hitTarget()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("About \(title)")
    }
}

/// What a widget shows when it has nothing to show. Every blank state on the
/// dashboard is this view, so "no data yet" never renders as a broken tile,
/// a flat zero line, or — worst — a `0` that reads as a real balance
/// (money rule 5).
struct WidgetEmptyState: View {
    let systemImage: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(Color.secondary.opacity(0.7))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    // HIG minimum target: the label alone is ~20pt tall.
                    .frame(minWidth: WidgetStyle.minimumTarget, minHeight: WidgetStyle.minimumTarget)
                    .contentShape(Rectangle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 4)
    }
}

/// The dashboard's trend badge — arrow, figure, and what it is being
/// compared against, in a tinted pill.
///
/// **The caption is never dropped and never abbreviated.** "−2.2 pts" on its
/// own is not a fact a reader can use: down against last month, against the
/// month before the one they highlighted, and against a twelve-month average
/// are three different pieces of news, and the pill is the only place the
/// widget says which one it means. Where the full phrase doesn't fit on one
/// line — a 2×1 tile is about 146pt wide inside its padding, and "↘ 2.2 pts
/// vs last month" needs more than that — it wraps onto a second line rather
/// than shrinking the type or truncating to "vs last mo…".
///
/// Its colour comes from `DashboardTrend` rather than from a parameter, so
/// no two widgets can end up disagreeing about what green means.
struct WidgetTrendBadge: View {
    let percentChange: Double?
    /// What the number is measured in. `%` for a change in an amount; `pts`
    /// for a change in something that is *already* a percentage — going from
    /// 30% to 33% is "+3 pts", and calling that "+10%" would be arithmetically
    /// true of the ratio and useless to the reader.
    var unit: String = "%"
    var caption: String?

    var body: some View {
        // One line where it fits, two where it doesn't. `ViewThatFits`
        // measures against the width the tile actually has, so the same
        // badge is a single line on an expanded 4×2 and two lines on a
        // collapsed 2×1 without either being a special case.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                figure
                captionText
            }
            VStack(alignment: .leading, spacing: 0) {
                figure
                captionText
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(DashboardTrend.color(for: percentChange))
        .monospacedDigit()
        // The pill is tinted by the trend rather than a flat grey, so the
        // badge still reads as up/down/unknown at a glance without the
        // caption having to be read. Kept faint — it is a backing for the
        // number, not a second coloured object competing with the figure
        // above it.
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(DashboardTrend.color(for: percentChange).opacity(0.14), in: Capsule())
    }

    private var figure: some View {
        HStack(spacing: 4) {
            if let percentChange {
                Image(systemName: percentChange >= 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.caption2.weight(.bold))
                Text(String(format: unit == "%" ? "%.1f%%" : "%.1f \(unit)", abs(percentChange)))
            } else {
                // Money rule 5 — an uncomputable change is "—", never 0.0%.
                Text("—")
            }
        }
        .lineLimit(1)
    }

    @ViewBuilder
    private var captionText: some View {
        if let caption {
            Text(caption)
                .foregroundStyle(Color.secondary)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/// A soft wash of the card's own surface behind a figure that sits over a
/// chart.
///
/// Net Worth and FX Rate both draw their trajectory across the full width of
/// the collapsed tile, headline included — which is the point, the line is
/// the tile's texture. But a line crossing a digit at the wrong angle makes
/// the digit hard to read, and the headline is the one thing on the tile that
/// must never be hard to read.
///
/// **The wash is the card's own fill, not a material.** A blurring material
/// was the first attempt and it was visibly wrong: a material lightens
/// whatever it covers, so the top of the card came out a different tone from
/// the bottom and the tile looked like it had a panel laid over it. Painting
/// in the card's exact colour changes no colour anywhere — all it does is
/// hide the line — so there is nothing for a seam to be a seam *between*.
///
/// The fade is deliberately long and runs well past the text. A short one
/// finishes inside the tile and puts a horizontal edge where it ends, which
/// is the one artefact this is supposed not to have.
struct MetricLegibilityScrim: ViewModifier {
    func body(content: Content) -> some View {
        content.background {
            LinearGradient(
                stops: [
                    .init(color: Color(.secondarySystemGroupedBackground), location: 0),
                    .init(color: Color(.secondarySystemGroupedBackground).opacity(0.94), location: 0.5),
                    .init(color: Color(.secondarySystemGroupedBackground).opacity(0), location: 1)
                ],
                startPoint: .top, endPoint: .bottom
            )
            // Out to the card's edges sideways, and a long way below the
            // text, so the gradient has room to reach zero before it runs
            // out of tile.
            //
            // **Never upwards.** This is a background of the card's
            // *content*, and the content is laid out after the header, so
            // anything bleeding above the content's own top edge is painted
            // over the widget's title. It was, at first: the wash is opaque
            // at its top, so Net Worth and FX Rate wore their titles half
            // erased. The chart never reaches up there anyway — there is
            // nothing above the content to hide.
            .padding(.horizontal, -WidgetStyle.padding)
            .padding(.bottom, -48)
            .allowsHitTesting(false)
        }
    }
}

extension View {
    /// Makes a figure readable over the chart drawn behind it.
    func metricLegibilityScrim() -> some View { modifier(MetricLegibilityScrim()) }
}

/// One rule for what a trend's colour means, shared by every widget that
/// shows one. Green up / red down is the stock-app convention Home already
/// used before the dashboard existed, and `nil` is grey rather than green —
/// "we could not compute this" must never look like good news.
enum DashboardTrend {
    static func color(for percentChange: Double?) -> Color {
        guard let percentChange else { return .secondary }
        return percentChange >= 0 ? .green : .red
    }

    /// Period-over-period change as a percentage, or `nil` when it cannot be
    /// computed — either side missing (a missing FX rate propagates, money
    /// rule 5) or a zero baseline, which has no meaningful percentage.
    static func percentChange(from previous: Int64?, to current: Int64?) -> Double? {
        guard let current, let previous, previous != 0 else { return nil }
        return Double(current - previous) / Double(abs(previous)) * 100
    }
}
