import KeepoCore
import SwiftUI

/// The two ends of a transfer, as the form draws them: the account money
/// leaves, then the account it arrives in.
enum TransferSide {
    case source
    case destination
}

/// Two account+amount blocks with the direction of travel drawn down their
/// left — what a transfer literally is, and the shape both forms that can
/// create one are built from.
///
/// Extracted from `TransactionDetailCard` when recurring transfers landed:
/// the rule form asks the same question (out of which account, into which,
/// how much) and had no business answering it with its own layout. What the
/// two forms do NOT share is the card around this — a transaction carries
/// tags and a note, a rule carries a frequency — so the legs are the
/// component and the card is not.
///
/// The arrow rail runs down the left of both containers rather than sitting
/// between them: a glyph in the gap reads as a divider, while a line that
/// starts at one block and ends at the other reads as flow.
struct TransferLegsView: View {
    @Binding var fromAccountId: UUID?
    @Binding var toAccountId: UUID?
    @Binding var amountText: String
    @Binding var receivedAmountText: String

    let accounts: [LocalAccountRow]
    /// What the DESTINATION picker may offer, when that is narrower than
    /// `accounts`. `nil` means the same list on both ends.
    ///
    /// Both forms narrow it rather than offering a destination the save would
    /// then refuse: the transaction form to what `TransferPairing` allows (one
    /// owner, or both shared into the household), the recurring form further
    /// still, to one owner and one currency (migration 20260927100000).
    var destinationAccounts: [LocalAccountRow]?
    /// Only meaningful when the two accounts hold different currencies —
    /// otherwise the received amount is the sent amount and asking for it
    /// twice is asking the user to agree with themselves.
    let needsReceivedAmount: Bool
    /// Off for a recurring transfer, whose amount comes from the rule rather
    /// than from a purchase that needs working out.
    var showsAmountCalculator = true
    /// The end that is on an account this viewer cannot see — a household
    /// member's private account, whose leg RLS never sends here. Drawn as a
    /// named blank rather than as a picker reading "Choose account" over an
    /// amount the device does not have: an empty control says "fill me in",
    /// and this is not something the viewer can fill in.
    var hiddenSide: TransferSide?

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.s) {
            FlowRail()
            VStack(spacing: AppTheme.Spacing.m) {
                if hiddenSide == .source {
                    HiddenTransferLegContainer()
                } else {
                    TransactionDetailContainer(
                        accountId: $fromAccountId,
                        amountText: $amountText,
                        accounts: accounts,
                        excluding: toAccountId,
                        showsAmountCalculator: showsAmountCalculator
                    )
                }
                if hiddenSide == .destination {
                    HiddenTransferLegContainer()
                } else {
                    TransactionDetailContainer(
                        accountId: $toAccountId,
                        // Same-currency transfers mirror the sent amount rather
                        // than offering a second field that can only ever hold
                        // the same number.
                        amountText: needsReceivedAmount ? $receivedAmountText : $amountText,
                        accounts: destinationAccounts ?? accounts,
                        excluding: fromAccountId,
                        isAmountEditable: needsReceivedAmount,
                        showsAmountCalculator: showsAmountCalculator
                    )
                }
            }
        }
    }
}

/// One end of a transfer the viewer cannot see, in the same chrome as the
/// end they can, so the pair still reads as a pair.
private struct HiddenTransferLegContainer: View {
    var body: some View {
        HStack(spacing: AppTheme.Spacing.s) {
            CategoryIconView(icon: "lock", color: AppTheme.Palette.textSecondary)
            Text("An account only its owner can see")
                .font(AppTheme.Typography.labelEmphasis)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(AppTheme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Palette.bgSurfaceRaised, in: RoundedRectangle(cornerRadius: AppTheme.Radius.card))
    }
}

/// Money leaving the top block and arriving in the bottom one.
private struct FlowRail: View {
    var body: some View {
        VStack(spacing: 0) {
            Circle()
                .fill(AppTheme.Palette.fillStrong)
                .frame(width: AppTheme.Size.dot, height: AppTheme.Size.dot)
            Rectangle()
                .fill(AppTheme.Palette.fillStrong)
                .frame(width: 1.5)
                .frame(maxHeight: .infinity)
            Image(systemName: "arrowtriangle.down.fill")
                .font(AppTheme.Typography.nano)
                .foregroundStyle(AppTheme.Palette.fillStrong)
        }
        .padding(.vertical, AppTheme.Spacing.l)
        .accessibilityLabel("Money moves from the first account to the second")
    }
}
