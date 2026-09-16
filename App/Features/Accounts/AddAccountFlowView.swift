import KeepoCore
import SwiftUI

/// The entire "Add Account" sheet: one `NavigationStack`, rooted at the
/// two-card kind chooser, pushing to `AccountFormView` once a kind is
/// picked — a push, not a second modal, so canceling mid-flow is always
/// exactly one gesture (swipe down) regardless of which screen the user is
/// on. Kind is picked here, once, and never again (`AccountFormView` never
/// offers a kind picker; kind stays immutable after creation, same as
/// `currency`). Both kinds behave identically now (income/expense/transfer,
/// card mapping — all offered on both), so this screen isn't sorting the
/// account into a different set of capabilities, only choosing whether it
/// carries the permanent `InvestmentBadge` everywhere it's shown afterward.
struct AddAccountFlowView: View {
    let session: SessionStore
    var onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedKind: PublicSchema.AccountKind?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.l) {
                Text("What are you tracking?")
                    .font(AppTheme.Typography.cardTitle)
                    .padding(.top, AppTheme.Spacing.xs)

                AccountKindPicker { kind in
                    selectedKind = kind
                }

                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppTheme.Spacing.l)
            .background(AppTheme.Palette.bgCanvas)
            .navigationTitle("New Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
            .navigationDestination(item: $selectedKind) { kind in
                AccountFormView(
                    session: session, mode: .create(kind: kind), onSaved: onSaved,
                    embedInNavigationStack: false, onDismissRequested: { dismiss() }
                )
            }
        }
    }
}

/// The two-card VStack itself, with no surrounding chrome. One caller —
/// `AddAccountFlowView`'s root, a screen whose only job is this choice,
/// which is the size these cards are drawn for.
///
/// Setup's first-account step asks the same question with a segmented
/// control instead: it has a name, an icon and a balance to fit underneath,
/// and at this size the cards pushed all three below the fold. It reads its
/// labels from `title(for:)` / `subtitle(for:)` below, so the two places
/// cannot drift apart on what the kinds are called or what they mean —
/// which is what sharing the whole view used to buy.
///
/// Both kinds behave identically (income/expense/transfer, card mapping —
/// all offered on either), so these cards are not sorting the account into
/// different capabilities. Since migration 20260903100000 the choice is not
/// even permanent any more: dragging a row between the two groups on the
/// Accounts list converts it. That is why the copy leans on what the user
/// is *tracking* rather than warning them to choose carefully.
struct AccountKindPicker: View {
    let onSelect: (PublicSchema.AccountKind) -> Void

    /// What each kind is called and what it means, as the single source of
    /// both. The cards below render them, and so does setup's first-account
    /// step, which asks the same question with a segmented control because
    /// it has a form to fit underneath it — two screens describing
    /// "Everyday" differently would be the drift this avoids.
    static func title(for kind: PublicSchema.AccountKind) -> String {
        switch kind {
        case .regular: return "Everyday"
        case .investment: return "Investment"
        }
    }

    static func subtitle(for kind: PublicSchema.AccountKind) -> String {
        switch kind {
        case .regular: return "Checking, cash, credit card, loan — money you spend and receive."
        case .investment: return "Brokerage, retirement, or anything you track as an investment."
        }
    }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.m) {
            kindCard(kind: .regular, icon: "creditcard.fill")
            kindCard(kind: .investment, icon: "chart.line.uptrend.xyaxis")
        }
    }

    private func kindCard(kind: PublicSchema.AccountKind, icon: String) -> some View {
        let title = Self.title(for: kind)
        let subtitle = Self.subtitle(for: kind)
        return Button {
            onSelect(kind)
        } label: {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
                Image(systemName: icon)
                    .font(AppTheme.Typography.sectionTitle)
                    .foregroundStyle(AppTheme.Palette.textPrimary)
                    .frame(width: AppTheme.Size.avatar, height: AppTheme.Size.avatar)
                    .background(AppTheme.Palette.bgSurfaceRaised, in: Circle())

                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text(title)
                        .font(AppTheme.Typography.cardTitle)
                        .foregroundStyle(AppTheme.Palette.textPrimary)
                    Text(subtitle)
                        .font(AppTheme.Typography.label)
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(AppTheme.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.Palette.bgSurface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.surface))
        }
        .buttonStyle(.pressableCard)
        .sensoryFeedback(AppTheme.Feedback.selection, trigger: title)
        .accessibilityLabel("\(title). \(subtitle)")
    }
}
