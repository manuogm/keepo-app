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
    /// `unshare_account` forks the account into an independent copy for the
    /// other household member (migration 20260816100000). They keep
    /// everything; what ends is the two of you seeing the same account. That
    /// is a surprising enough outcome to spell out.
    func unshareConfirmation(isPresented: Binding<Bool>, onConfirm: @escaping () -> Void) -> some View {
        confirmationDialog("Stop sharing this account?", isPresented: isPresented, titleVisibility: .visible) {
            Button("Stop Sharing", role: .destructive, action: onConfirm)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Your household member keeps their own independent copy of this account and its "
                    + "transactions. Nothing is lost, but the two copies stop staying in step."
            )
        }
    }
}

/// Currency choice, create-mode only — an account's currency is immutable
/// once it exists (no RPC changes it), which is why the edit form renders the
/// symbol in front of the figure instead of a disabled version of this.
///
/// A searchable list rather than a wheel `Picker`: the ECB/Frankfurter set
/// is ~30 entries, which is exactly the size where scrolling a wheel is
/// slower than typing three letters.
struct CurrencyPickerSheet: View {
    let currencies: [PublicSchema.CurrenciesSelect]
    @Binding var selection: String

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
                            .font(.body.weight(.medium))
                            .foregroundStyle(Color.primary)
                        Text(MoneyFormatter.symbol(for: CurrencyInfo(
                            code: currency.code, minorUnit: Int(currency.minorUnit)
                        )))
                            .foregroundStyle(Color.secondary)
                        Spacer()
                        if selection == currency.code {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                        }
                    }
                }
                .buttonStyle(.pressableRow)
            }
            .searchable(text: $query, prompt: "Currency code")
            .navigationTitle("Currency")
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
