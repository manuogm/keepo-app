import KeepoCore
import SwiftUI

// The account form's two confirmations and its currency picker, split out of
// AccountFormView.swift purely to keep that file under the project's
// file-length lint threshold.
//
// These take a `Binding` and a closure, NOT the `AccountFormView` itself.
// They used to take the whole view — `.deleteAccountDialog(self)` — which
// reads harmlessly and is a genuine crash: capturing `self` inside a view's
// own `body` makes the modifier's stored closure hold a copy of the view
// while that view is mid-construction. It survived by luck until the form
// grew another `@State` property, then started segfaulting inside
// `initializeWithCopy` before the sheet could draw anything (EXC_BAD_ACCESS,
// caught on device — the crash report's top frames were
// `AccountFormView.formContent.getter` → `ViewBuilder.buildExpression`).
// A modifier should never need more than the values it actually reads.

extension View {
    /// Deleting an account is two genuinely different operations and the
    /// user is entitled to know that before choosing. Archiving keeps every
    /// transaction and only drops the account out of totals; deleting is
    /// permanent, and the DB refuses it outright while transactions still
    /// reference the account. Offering only "Delete" would mean most taps
    /// end in an error explaining the option that should have been there.
    func deleteAccountDialog(
        accountName: String,
        isPresented: Binding<Bool>,
        onArchive: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) -> some View {
        confirmationDialog("Delete \"\(accountName)\"?", isPresented: isPresented, titleVisibility: .visible) {
            Button("Archive Account", action: onArchive)
            Button("Delete Permanently", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Archiving removes this account from your totals but keeps it and its transactions. "
                    + "Deleting is permanent, and is only possible while the account has no transactions."
            )
        }
    }

    /// Turning sharing off is not the inverse of turning it on: server-side,
    /// `unshare_account` hands the other household member a copy of what they
    /// could see (20261012100000), and sharing again later replaces that copy
    /// (20261014100000). That is a surprising enough outcome to spell out.
    func unshareConfirmation(isPresented: Binding<Bool>, onConfirm: @escaping () -> Void) -> some View {
        confirmationDialog("Stop sharing this account?", isPresented: isPresented, titleVisibility: .visible) {
            Button("Stop Sharing", role: .destructive, action: onConfirm)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Your account stays exactly as it is. Your household member keeps a copy of what they could "
                    + "see, which is replaced if you share this account again."
            )
        }
    }

    /// Sharing an account asks how much of it: from today, or its past too —
    /// the same question the household setup asks with a switch under each
    /// account (user's decision, 2026-09-23). "From today" comes first because
    /// it is the default everywhere else.
    ///
    /// Two buttons rather than a switch and a Share button: there is no third
    /// state, and the choice *is* the action.
    func shareAccountDialog(
        accountName: String, isPresented: Binding<Bool>, onShare: @escaping (_ fullHistory: Bool) -> Void
    ) -> some View {
        confirmationDialog(
            "Share \"\(accountName)\" with your household?", isPresented: isPresented, titleVisibility: .visible
        ) {
            Button("Share From Today") { onShare(false) }
            Button("Include Past Transactions") { onShare(true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "From today, your household sees this account's new transactions and its past stays private. "
                    + "You can include the past later, but not hide it again."
            )
        }
    }

    /// Widening a share that began on a date. It has no way back — narrowing
    /// a share is not offered — so it says so.
    func includePastConfirmation(isPresented: Binding<Bool>, onConfirm: @escaping () -> Void) -> some View {
        confirmationDialog("Include past transactions?", isPresented: isPresented, titleVisibility: .visible) {
            Button("Include Past Transactions", action: onConfirm)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Your household will see every transaction on this account, not only those since you shared it. "
                    + "This can't be undone."
            )
        }
    }
}

/// Pick one currency out of the supported set.
///
/// A searchable list rather than a wheel `Picker`: the ECB/Frankfurter set
/// is ~30 entries, which is exactly the size where scrolling a wheel is
/// slower than typing three letters. (`BaseCurrencySheet` on My Profile is
/// a wheel and says the opposite — that one is picked once, from a currency
/// you already hold; these two are picked while you are looking for a
/// specific code you already know.)
///
/// **Two callers**, which is why `title` exists. The account form uses it
/// create-mode only — an account's currency is immutable once it exists (no
/// RPC changes it), which is why the edit form renders the symbol in front
/// of the figure instead of a disabled version of this. The transaction
/// form uses it for "what did you pay in?", where the answer genuinely
/// changes per purchase.
struct CurrencyPickerSheet: View {
    let currencies: [PublicSchema.CurrenciesSelect]
    @Binding var selection: String
    var title = "Currency"

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [PublicSchema.CurrenciesSelect] {
        guard !query.isEmpty else { return currencies }
        return currencies.filter { $0.code.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List(filtered, id: \.code) { currency in
                Button {
                    selection = currency.code
                    dismiss()
                } label: {
                    HStack {
                        Text(currency.code)
                            .font(AppTheme.Typography.bodyEmphasis)
                            .foregroundStyle(AppTheme.Palette.textPrimary)
                        Text(MoneyFormatter.symbol(for: CurrencyInfo(
                            code: currency.code, minorUnit: Int(currency.minorUnit)
                        )))
                            .foregroundStyle(AppTheme.Palette.textSecondary)
                        Spacer()
                        if selection == currency.code {
                            Image(systemName: "checkmark")
                                .font(AppTheme.Typography.bodyEmphasis)
                        }
                    }
                }
                .buttonStyle(.pressableRow)
            }
            .searchable(text: $query, prompt: "Currency code")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
