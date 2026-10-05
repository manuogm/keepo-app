import SwiftUI

/// The account's name and its markers, as the header of the balance field.
///
/// **"Investment" gives way to "Inv." only when the name needs the room** —
/// when the name, the full badge and the shared marker together would not
/// fit on the line, which is what happens once a long balance sends the
/// currency pill and calculator up into this row. A name that fits keeps
/// the spelled-out badge; one that would be cut gets the badge's room
/// instead. Measured against the full badge, never the one on screen, so
/// the choice cannot flip-flop as the badge changes size.
///
/// Every account is named through this row — the account form and
/// onboarding's first account alike — so the badge stepping left for the
/// pill, and shortening when the name needs the room, is one behaviour
/// rather than two that drift.
struct AccountNameRow: View {
    @Binding var name: String
    let isInvestment: Bool
    let isShared: Bool

    @State private var rowWidth: CGFloat = 0
    @State private var nameWidth: CGFloat = 0
    @State private var fullMarkersWidth: CGFloat = 0

    private var needsShortBadge: Bool {
        rowWidth > 0 && nameWidth + AppTheme.Spacing.s + fullMarkersWidth > rowWidth
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.s) {
            TextField("Account Name", text: $name)
                .font(AppTheme.Typography.cardTitle)
                .textInputAutocapitalization(.words)
            markers(shortBadge: needsShortBadge)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
        .background(alignment: .leading) {
            // The placeholder counts: an empty field still shows it.
            Text(name.isEmpty ? "Account Name" : name)
                .font(AppTheme.Typography.cardTitle)
                .hidden()
                .onIdealWidthChange { nameWidth = $0 }
            HStack(spacing: AppTheme.Spacing.s) { markers(shortBadge: false) }
                .hidden()
                .onIdealWidthChange { fullMarkersWidth = $0 }
        }
    }

    @ViewBuilder
    private func markers(shortBadge: Bool) -> some View {
        if isInvestment {
            InvestmentBadge(compact: shortBadge)
        }
        if isShared {
            SharedWithHouseholdIcon()
        }
    }
}

private extension View {
    /// Reports the width this view would take if nothing constrained it,
    /// measured off a hidden, unconstrained copy — the view's own layout is
    /// untouched.
    func onIdealWidthChange(_ action: @escaping (CGFloat) -> Void) -> some View {
        background(alignment: .leading) {
            fixedSize()
                .hidden()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { action($0) }
        }
    }
}
