import KeepoCore
import SwiftUI

/// Report screen two: every account in the household, and whose it was.
///
/// Split into "Shared by you" and "Shared with you" rather than merged into
/// one alphabetical list, because at this exact moment the provenance is the
/// interesting part — the owner is checking that what they meant to share is
/// what went in, and that what arrived is what they expected.
struct HouseholdReportAccounts: View {
    let snapshot: HouseholdSnapshot
    let viewer: UUID?

    @State private var isMineExpanded = true
    @State private var isTheirsExpanded = true

    private var mine: [LocalAccountRow] { snapshot.accounts(ownedBy: viewer, mine: true) }
    private var theirs: [LocalAccountRow] { snapshot.accounts(ownedBy: viewer, mine: false) }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.l) {
            countsCard
            listCard
        }
    }

    private var countsCard: some View {
        HouseholdCard(title: "Household accounts") {
            HStack(alignment: .top, spacing: AppTheme.Spacing.l) {
                HouseholdMetric(value: snapshot.everydayCount, label: "Everyday")
                HouseholdMetric(value: snapshot.investmentCount, label: "Investment")
            }
        }
    }

    private var listCard: some View {
        HouseholdCard(title: "What's in it") {
            VStack(spacing: 0) {
                HouseholdDisclosure(
                    title: "Shared by you", count: mine.count, isExpanded: $isMineExpanded
                ) {
                    rows(mine)
                }
                Divider()
                HouseholdDisclosure(
                    title: "Shared with you", count: theirs.count, isExpanded: $isTheirsExpanded
                ) {
                    rows(theirs)
                }
            }
        }
    }

    private func rows(_ accounts: [LocalAccountRow]) -> some View {
        VStack(spacing: AppTheme.Spacing.xs) {
            ForEach(accounts) { account in
                HouseholdAccountRow(
                    name: account.name,
                    icon: account.icon,
                    color: Color(hex: account.color),
                    isInvestment: account.kind == .investment
                ) {
                    // Its own currency, not the viewer's. This list is about
                    // which accounts are in the household, and an account
                    // recognisable from the user's bank app is the point —
                    // the converted total already had its own card on the
                    // screen before this one.
                    PrivateText(MoneyFormatter.format(account.balanceE4, currency: account.currencyInfo))
                        .font(AppTheme.Typography.Number.inline)
                        .foregroundStyle(AppTheme.Palette.textPrimary)
                }
            }
        }
        .padding(.bottom, AppTheme.Spacing.s)
    }
}
