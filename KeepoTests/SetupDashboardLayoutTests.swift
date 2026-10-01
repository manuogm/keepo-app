import Foundation
import KeepoCore
import Testing
@testable import Keepo

/// The dashboard step's two non-visual decisions: which widgets a draft can
/// actually support, and how the six of them pack into rows.
///
/// Both matter beyond this screen. A widget offered to someone whose data
/// cannot fill it commits as a permanently dead tile, and the pack order is
/// the layout the user is choosing — so a change to either is invisible in
/// a screenshot and wrong forever afterwards.
@Suite("Setup dashboard step")
struct SetupDashboardLayoutTests {
    private func draft(_ change: (inout OnboardingDraft) -> Void = { _ in }) -> OnboardingDraft {
        var value = OnboardingDraft(baseCurrency: "EUR")
        value.account = DraftAccount(name: "Checking", kind: .regular, currency: "EUR")
        change(&value)
        return value
    }

    // MARK: - What the draft can support

    /// Day one, the common case: one everyday account in the base currency.
    /// Two widgets have nothing to say, and each says what to do about it
    /// rather than just being unavailable.
    @Test("a single everyday account in the base currency cannot fill FX or Investing Ratio")
    func plainAccount() {
        let capabilities = DashboardCapabilities(onboarding: draft())
        #expect(capabilities.unavailability(for: .investingRatio) != nil)
        #expect(capabilities.unavailability(for: .fxRate) != nil)
        #expect(capabilities.unavailability(for: .netWorth) == nil)
        #expect(capabilities.unavailability(for: .cashflow) == nil)
        #expect(capabilities.unavailability(for: .currencyExposure) == nil)
        #expect(capabilities.unavailability(for: .upcomingBills) == nil)
    }

    @Test("an investment account unlocks the investing ratio")
    func investmentAccount() {
        let capabilities = DashboardCapabilities(onboarding: draft { $0.account?.kind = .investment })
        #expect(capabilities.unavailability(for: .investingRatio) == nil)
    }

    /// The case Feature 3 sells: a first account in a currency other than
    /// the one the user thinks in. The FX widget has a pair to quote.
    @Test("an account in another currency unlocks the FX rate")
    func foreignAccount() {
        let capabilities = DashboardCapabilities(onboarding: draft { $0.account?.currency = "JPY" })
        #expect(capabilities.unavailability(for: .fxRate) == nil)
        #expect(capabilities.foreignCurrencies == ["JPY"])
    }

    /// The account step is not skippable, but the dashboard step can be
    /// reached with a draft restored from an older build — and answering
    /// "no account" with a crash or with every widget available would both
    /// be wrong.
    @Test("no account at all supports only the widgets that need none")
    func noAccount() {
        let capabilities = DashboardCapabilities(onboarding: draft { $0.account = nil })
        #expect(capabilities.hasInvestmentAccounts == false)
        #expect(capabilities.foreignCurrencies.isEmpty)
        #expect(capabilities.unavailability(for: .netWorth) == nil)
    }

    // MARK: - Pruning

    /// Going Back and changing the account takes a widget's data away
    /// underneath a selection already made. Left alone it commits as a tile
    /// that can never render.
    @Test("changing the account prunes a selection it can no longer support")
    func pruningDropsTheStranded() {
        let capabilities = DashboardCapabilities(onboarding: draft())
        let kept = SetupDashboardLayout.pruned(
            [.netWorth, .investingRatio, .cashflow], capabilities: capabilities
        )
        #expect(kept == [.netWorth, .cashflow])
    }

    /// **Order is the dashboard's layout.** A prune that re-sorted would
    /// silently rearrange widgets the user placed deliberately.
    @Test("pruning keeps the order of everything it keeps")
    func pruningPreservesOrder() {
        let capabilities = DashboardCapabilities(onboarding: draft())
        let kept = SetupDashboardLayout.pruned(
            [.cashflow, .fxRate, .upcomingBills, .netWorth], capabilities: capabilities
        )
        #expect(kept == [.cashflow, .upcomingBills, .netWorth])
    }

    @Test("a selection the draft fully supports is left alone")
    func pruningIsANoOpWhenNothingIsStranded() {
        let capabilities = DashboardCapabilities(onboarding: draft())
        let metrics: [DashboardWidgetKind] = [.netWorth, .cashflow, .upcomingBills]
        #expect(SetupDashboardLayout.pruned(metrics, capabilities: capabilities) == metrics)
    }
}
