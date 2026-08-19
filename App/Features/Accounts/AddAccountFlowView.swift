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
            VStack(spacing: 16) {
                Text("What kind of account is this?")
                    .font(.callout)
                    .foregroundStyle(Color.secondary)
                    .padding(.top, 8)

                AccountKindPicker { kind in
                    selectedKind = kind
                }

                Spacer()
            }
            .padding(24)
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
struct AccountKindPicker: View {
    let onSelect: (PublicSchema.AccountKind) -> Void

    var body: some View {
        VStack(spacing: 12) {
            kindCard(
                kind: .regular,
                title: "Regular Account",
                subtitle: "Checking, cash, credit card, loan — everyday spending and income.",
                icon: "creditcard"
            )
            kindCard(
                kind: .investment,
                title: "Investment Account",
                subtitle: "Brokerage, retirement, or any account you're tracking as an investment.",
                icon: "chart.line.uptrend.xyaxis"
            )
        }
    }

    private func kindCard(kind: PublicSchema.AccountKind, title: String, subtitle: String, icon: String) -> some View {
        Button {
            onSelect(kind)
        } label: {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor.opacity(0.15), in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(Color.primary)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}
