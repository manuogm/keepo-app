import Testing
@testable import Keepo

/// The ceremony's progress ladder.
///
/// It used to be ten equal ninths, which made the three steps that sit in
/// front of real server work — `accept_invite` returning, the fuzzy pass and
/// its merge RPC, the final sync — indistinguishable from the six that are
/// naming something an earlier gate already made true. These pin the shape
/// rather than the numbers: what matters is that it climbs, that it stops at
/// 90%, and that it is not a constant.
@Suite("Ceremony progress")
struct HouseholdCeremonyPhaseTests {
    private let phases = HouseholdCeremonyPhase.allCases

    @Test("the house only ever fills")
    func fillIsStrictlyIncreasing() {
        for (earlier, later) in zip(phases, phases.dropFirst()) {
            #expect(earlier.fill < later.fill, "\(earlier) → \(later) did not advance")
        }
    }

    @Test("and stops at 90%, leaving the last tenth for Finish")
    func lastPhaseStopsShort() {
        #expect(phases.first?.fill ?? 0 > 0)
        #expect((phases.last?.fill ?? 0).isApproximately(0.9))
    }

    /// The regression: a constant step is the thing being removed.
    @Test("no two steps are worth the same amount of progress")
    func stepsAreNotUniform() {
        let steps = zip(phases, phases.dropFirst()).map { $1.fill - $0.fill }
        #expect(Set(steps.map { ($0 * 1000).rounded() }).count > 1)
    }

    @Test("the steps with a server call behind them are the big ones")
    func theWorkCarriesTheWeight() {
        let gated: [HouseholdCeremonyPhase] = [.receivingAccounts, .mergingCategories, .buildingHousehold]
        let narrated: [HouseholdCeremonyPhase] = [.sharingProfiles, .sharingAccounts, .mergingTags]
        let lightest = gated.map(\.weight).min() ?? 0
        let heaviest = narrated.map(\.weight).max() ?? 0
        #expect(lightest > heaviest)
    }

    /// Pacing and percentage have to tell one story: a step worth 5% that sat
    /// on screen as long as the one worth 20% is the same lie in a different
    /// place.
    @Test("time on screen follows the same weighting")
    func durationFollowsWeight() {
        for phase in phases {
            for other in phases where phase.weight < other.weight {
                #expect(phase.minimumDuration < other.minimumDuration)
            }
        }
    }

    /// Two people read these words off two phones at once.
    @Test("and never drops below what a step name takes to read")
    func durationHasAFloor() {
        #expect(phases.allSatisfy { $0.minimumDuration >= .milliseconds(800) })
    }

    /// `mirrored` is wording, never position — deriving progress from it made
    /// the guest's percentage step backwards.
    @Test("mirroring a phase never changes how much of the house is filled")
    func mirroringIsWordingOnly() {
        for phase in phases where phase.mirrored != phase {
            #expect(phase.mirrored.mirrored == phase)
        }
    }
}

private extension Double {
    func isApproximately(_ other: Double) -> Bool { abs(self - other) < 0.0001 }
}
