import KeepoCore
import SwiftUI

// The provenance line at the foot of the transaction card — where this entry
// came from, and whether it can happen again on its own — plus the seed it
// hands the recurring-rule form. Split out of TransactionFormView.swift for
// the project's file-length lint, same precedent as
// TransactionFormView+Date.swift.
//
// Nothing here is `private`, for that reason alone.

extension TransactionFormView {
    /// One grey line that answers "where did this come from, and can it
    /// happen again on its own?" — three states, never two at once:
    /// captured rows say so and stop there (a capture cannot be turned into
    /// a rule, it already happened); a row that is already an instance of a
    /// rule says so; anything else offers to become one.
    @ViewBuilder
    var recurringLine: some View {
        if isCaptured {
            recurringLabel("Automatically captured", icon: "icon-robot")
        } else if editingRecurringRuleId != nil {
            recurringLabel("Recurring", icon: "icon-recurrent")
        } else if canRecur {
            Button {
                isCreatingRecurringRule = true
            } label: {
                // Filled only in this branch. The other two states are
                // statements of fact, not buttons — giving all three the same
                // pill would promise a tap that two of them do not honour.
                recurringLabel("Make recurring", icon: "icon-recurrent")
                    .padding(.horizontal, AppTheme.Spacing.m)
                    .padding(.vertical, AppTheme.Spacing.s)
                    .background(AppTheme.Palette.bgSurfaceRaised, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.pressableCard)
        }
    }

    func recurringLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            KeepoIcon(name: icon, size: AppTheme.Size.glyphNano)
            Text(title)
        }
        .font(AppTheme.Typography.micro)
        .foregroundStyle(AppTheme.Palette.textSecondary)
    }

    /// Whether what is on screen is something a rule can actually describe.
    ///
    /// Transfers used to be excluded outright — `recurring_rules` held a
    /// single account/category pair and had no shape for one. Migration
    /// 20260927100000 gave it one, with two restrictions that both come from
    /// a rule firing unattended: the two accounts must share an owner, and
    /// they must share a currency (there is no honest destination amount to
    /// store for a conversion nobody is present to correct — money rule 6).
    ///
    /// A transfer that fails either test gets no button rather than a button
    /// that pushes a form which cannot save. This line has room for a label,
    /// not for an explanation; the recurring form carries the explanation for
    /// anyone who arrives there directly.
    var canRecur: Bool {
        guard kind == .transfer else { return true }
        guard let source = fromAccount, let destination = toAccount else { return false }
        return source.ownerId == destination.ownerId && source.currency == destination.currency
    }

    /// Seeds the recurring-rule form from what is already on screen, so
    /// "make this happen every month" does not mean retyping the accounts,
    /// amount and category that are right there.
    var recurringSeedMode: RecurringRuleFormView.Mode {
        .createSeeded(
            accountId: selectedAccountId,
            toAccountId: kind == .transfer ? selectedToAccountId : nil,
            categoryId: kind == .transfer ? nil : selectedCategoryId,
            amountText: amountText,
            kind: recurringKind,
            startingOn: occurredAt,
            title: title,
            notes: notes,
            tagIds: selectedTagIds
        )
    }

    /// The two forms deliberately name their kinds the same three words, so
    /// this is a straight mapping and not a translation. It exists because
    /// they are two separate enums — one locked in edit mode, one not — and
    /// sharing a type would have meant sharing that rule too.
    var recurringKind: RecurringRuleFormView.Kind {
        switch kind {
        case .expense: return .expense
        case .income: return .income
        case .transfer: return .transfer
        }
    }
}
