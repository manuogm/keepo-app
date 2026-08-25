import KeepoCore
import SwiftUI

/// The one card every dashboard widget draws itself into. Cohesion on this
/// screen is not a styling preference — five widgets showing five unrelated
/// kinds of information only read as one dashboard if the surface, the
/// corner, the padding, and the header are literally the same view rather
/// than five approximations of the same idea.
///
/// A widget supplies a title, a glyph, and its body. Everything else — fill,
/// radius, insets, header typography, how the header sits above the content —
/// is decided here and nowhere else.
/// Constants shared by the chrome and by anything that has to match its
/// shape (a drag preview, a drop highlight). A plain enum rather than a
/// static on `WidgetChrome` itself, which is generic — `WidgetChrome<EmptyView>
/// .cornerRadius` at a call site that doesn't otherwise care about the
/// content type is noise.
enum WidgetStyle {
    static let cornerRadius: CGFloat = 22
    static let padding: CGFloat = 14
    /// The smallest a control on this dashboard may be, per Apple's HIG.
    /// Applied as a *hit* area rather than as visible furniture — a 44pt
    /// capsule around every W/M/Y segment would swamp a widget header — so
    /// the control keeps its drawn size and grows its `contentShape`.
    static let minimumTarget: CGFloat = 44
}

struct WidgetChrome<Content: View>: View {
    let title: String
    let systemImage: String
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
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption)
            Text(title)
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            accessory?()
        }
        .foregroundStyle(Color.secondary)
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
        VStack(spacing: 6) {
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

/// The dashboard's trend badge — arrow plus percentage, sized to survive a
/// 1×1 tile, with an optional caption for the tiles that have room for one.
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
        HStack(spacing: 3) {
            if let percentChange {
                Image(systemName: percentChange >= 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.caption2.weight(.bold))
                Text(String(format: unit == "%" ? "%.1f%%" : "%.1f \(unit)", abs(percentChange)))
                if let caption {
                    Text(caption)
                        .foregroundStyle(Color.secondary)
                }
            } else {
                // Money rule 5 — an uncomputable change is "—", never 0.0%.
                Text("—")
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(DashboardTrend.color(for: percentChange))
        .monospacedDigit()
        .lineLimit(1)
        // The pill is tinted by the trend rather than a flat grey, so the
        // badge still reads as up/down/unknown at a glance without the
        // caption having to be read. Kept faint — it is a backing for the
        // number, not a second coloured object competing with the figure
        // above it.
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(DashboardTrend.color(for: percentChange).opacity(0.14), in: Capsule())
    }
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
