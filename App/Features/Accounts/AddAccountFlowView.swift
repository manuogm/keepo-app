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

/// The two-card VStack itself, with no surrounding chrome — shared by
/// `AddAccountFlowView`'s root and `OnboardingView`'s first-account step (an
/// inline step in an already-full-screen flow, wraps this in its own header
/// text instead), so the two entry points can never drift apart on what the
/// two cards say or look like.
///
/// Both kinds behave identically (income/expense/transfer, card mapping —
/// all offered on either), so these cards are not sorting the account into
/// different capabilities. Since migration 20260903100000 the choice is not
/// even permanent any more: dragging a row between the two groups on the
/// Accounts list converts it. That is why the copy leans on what the user
/// is *tracking* rather than warning them to choose carefully.
struct AccountKindPicker: View {
    let onSelect: (PublicSchema.AccountKind) -> Void

    var body: some View {
        VStack(spacing: AppTheme.Spacing.m) {
            kindCard(
                kind: .regular,
                title: "Everyday",
                subtitle: "Checking, cash, credit card, loan — money you spend and receive.",
                icon: "creditcard.fill"
            )
            kindCard(
                kind: .investment,
                title: "Investment",
                subtitle: "Brokerage, retirement, or anything you track as an investment.",
                icon: "chart.line.uptrend.xyaxis"
            )
        }
    }

    private func kindCard(
        kind: PublicSchema.AccountKind, title: String, subtitle: String, icon: String
    ) -> some View {
        Button {
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
