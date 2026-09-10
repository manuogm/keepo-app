import Foundation
import Testing

@testable import KeepoCore

/// The pairs the threshold was chosen against.
///
/// This suite is the reason `CategoryNameMatcher.threshold` is allowed to be
/// a single tuned number: moving it fails a named pair here, so the change
/// says out loud which two categories you have just decided are (or are not)
/// the same thing. Every case below is a real collision between two people's
/// category lists, not a synthetic string.
@Suite("Category name matching")
struct CategoryNameMatcherTests {
    // MARK: - Matches

    @Test(
        "near-misses that are the same category",
        arguments: [
            ("Dine Out", "Dining Out"),
            ("Transport", "Transportation"),
            ("Rent", "Rental"),
            ("Groceries", "Grocery"),
            ("Salaries", "Salary"),
            ("Holidays", "Holiday"),
            ("Utilities", "Utility"),
            ("Expenses", "Expense"),
            ("Food & Drink", "Food and Drink"),
            ("Dining Out", "dining  out"),
            ("Out Dining", "Dining Out"),
            ("Subscriptions", "Subscription"),
        ]
    )
    func matches(pair: (String, String)) {
        let score = CategoryNameMatcher.similarity(pair.0, pair.1)
        #expect(
            score >= CategoryNameMatcher.threshold,
            "\(pair.0) / \(pair.1) scored \(score), below \(CategoryNameMatcher.threshold)"
        )
    }

    // MARK: - Non-matches

    @Test(
        "different categories that merely look alike",
        arguments: [
            ("Food", "Fuel"),
            ("Health", "Wealth"),
            ("Travel", "Transport"),
            ("Gifts", "Gas"),
            ("Rent", "Refund"),
            ("Savings", "Shopping"),
            ("Salary", "Solar"),
        ]
    )
    func nonMatches(pair: (String, String)) {
        let score = CategoryNameMatcher.similarity(pair.0, pair.1)
        #expect(
            score < CategoryNameMatcher.threshold,
            "\(pair.0) / \(pair.1) scored \(score), at or above \(CategoryNameMatcher.threshold)"
        )
    }

    // MARK: - Meaning, where spelling runs out

    /// Pairs no amount of threshold tuning could ever have found.
    ///
    /// Every one of these shares too little spelling to clear
    /// `gatedEditRatio` — several share none at all — and the only threshold
    /// low enough to admit them would also admit Health/Wealth. They match
    /// because `conceptLexicon` says the two words name the same thing, and
    /// they arrive at the scorer already identical.
    @Test(
        "synonyms that share no spelling",
        arguments: [
            ("Eating Out", "Dining Out"),
            ("Restaurants", "Dining Out"),
            ("Takeaway", "Eating Out"),
            ("Home", "House"),
            ("Gym", "Fitness"),
            ("Petrol", "Fuel"),
            ("Bills", "Utilities"),
            ("Kids", "Children"),
            ("Wages", "Salary"),
            ("Shopping", "Retail"),
            ("Holidays", "Travel"),
            ("Public Transport", "Commuting"),
            ("Mobile", "Phone"),
            ("Broadband", "Internet"),
        ]
    )
    func synonyms(pair: (String, String)) {
        let score = CategoryNameMatcher.similarity(pair.0, pair.1)
        #expect(
            score >= CategoryNameMatcher.threshold,
            "\(pair.0) / \(pair.1) scored \(score), below \(CategoryNameMatcher.threshold)"
        )
    }

    /// The lexicon is a list of decisions, so the words left off it are
    /// decisions too. "Food" means groceries to one person and eating out to
    /// another; "Gas" is a car in one country and a boiler in the next.
    /// Mapping either would pick a side and produce a confidently wrong
    /// merge — worse than the near-miss the lexicon exists to fix, because
    /// the merged pair is what the household then files against.
    @Test("ambiguous words stay their own concept")
    func ambiguousWordsAreNotMapped() {
        #expect(CategoryNameMatcher.concepts("Food") == ["food"])
        #expect(CategoryNameMatcher.concepts("Gas") == ["gas"])
        #expect(CategoryNameMatcher.similarity("Food", "Groceries") < CategoryNameMatcher.threshold)
        #expect(CategoryNameMatcher.similarity("Gas", "Fuel") < CategoryNameMatcher.threshold)
    }

    /// Spelling first, then meaning — `concepts` reads the singularized
    /// token, so a lexicon keyed on plurals would silently never fire.
    @Test("the lexicon reads singularized words")
    func lexiconRunsAfterSingularization() {
        #expect(CategoryNameMatcher.normalize("Restaurants") == ["restaurant"])
        #expect(CategoryNameMatcher.concepts("Restaurants") == ["dining"])
        #expect(CategoryNameMatcher.concepts("Dine Out") == ["dining", "out"])
    }

    // MARK: - Normalization

    @Test("plurals normalize onto their singular")
    func singularization() {
        #expect(CategoryNameMatcher.normalize("Groceries") == ["grocery"])
        #expect(CategoryNameMatcher.normalize("Expenses") == ["expense"])
        #expect(CategoryNameMatcher.normalize("Boxes") == ["box"])
        #expect(CategoryNameMatcher.normalize("Watches") == ["watch"])
        // Not a plural. "Fitnes" would match nothing and read as a typo.
        #expect(CategoryNameMatcher.normalize("Fitness") == ["fitness"])
        // Three letters or fewer keeps its "s" — "Gas" is not "Ga".
        #expect(CategoryNameMatcher.normalize("Gas") == ["gas"])
    }

    @Test("noise words and punctuation drop out")
    func noiseWords() {
        #expect(CategoryNameMatcher.normalize("Food & Drink") == ["food", "drink"])
        #expect(CategoryNameMatcher.normalize("The Car") == ["car"])
        #expect(CategoryNameMatcher.normalize("Café") == ["cafe"])
    }

    /// A name made only of noise must not normalize to nothing — an empty
    /// token list would score 0 against everything, or 1 against another
    /// empty one, and "The" would silently become every category's twin.
    @Test("a name of pure noise keeps its words")
    func allNoise() {
        #expect(CategoryNameMatcher.normalize("The") == ["the"])
        #expect(CategoryNameMatcher.similarity("The", "A") < CategoryNameMatcher.threshold)
    }

    @Test("identical names score exactly 1")
    func identity() {
        #expect(CategoryNameMatcher.similarity("Groceries", "groceries ") == 1)
    }

    @Test("an empty name matches nothing")
    func empty() {
        #expect(CategoryNameMatcher.similarity("", "Groceries") == 0)
        #expect(CategoryNameMatcher.similarity("   ", "Groceries") == 0)
    }

    // MARK: - Pairing

    /// One-to-one: "Dining Out" can only be spent once, so the stronger of
    /// the two claims on it wins and the weaker claimant goes unmatched into
    /// the report's Extra list rather than producing a second merge.
    @Test("a category is claimed by only one partner")
    func oneToOne() {
        let mine = [
            CategoryNameMatcher.Candidate(id: 1, name: "Dining Out"),
            // Not "Dine Out": the lexicon now makes that an exact match too,
            // and a tie proves nothing about ranking. "Diner Out" clears the
            // threshold on spelling alone and stays the weaker claim.
            CategoryNameMatcher.Candidate(id: 2, name: "Diner Out"),
        ]
        let theirs = [CategoryNameMatcher.Candidate(id: 10, name: "Dining Out")]

        let matches = CategoryNameMatcher.pair(mine: mine, theirs: theirs)

        #expect(matches.count == 1)
        // The exact match outranks the fuzzy one.
        #expect(matches.first?.mine == 1)
        #expect(matches.first?.theirs == 10)
    }

    @Test("unrelated lists produce no matches")
    func noOverlap() {
        let mine = [
            CategoryNameMatcher.Candidate(id: 1, name: "Groceries"),
            CategoryNameMatcher.Candidate(id: 2, name: "Rent"),
        ]
        let theirs = [
            CategoryNameMatcher.Candidate(id: 10, name: "Fuel"),
            CategoryNameMatcher.Candidate(id: 11, name: "Gifts"),
        ]

        #expect(CategoryNameMatcher.pair(mine: mine, theirs: theirs).isEmpty)
    }

    /// Two runs over the same lists must produce the same pairing, or the two
    /// phones in a household would narrate different merges to each other.
    @Test("pairing is stable across runs")
    func stability() {
        let mine = (1...6).map { CategoryNameMatcher.Candidate(id: $0, name: "Category \($0)") }
        let theirs = (10...15).map { CategoryNameMatcher.Candidate(id: $0, name: "Category \($0 - 9)") }

        let first = CategoryNameMatcher.pair(mine: mine, theirs: theirs)
        let second = CategoryNameMatcher.pair(mine: mine, theirs: theirs)

        #expect(first == second)
        #expect(!first.isEmpty)
    }

    @Test("every proposed match clears the threshold")
    func allAboveThreshold() {
        let mine = [
            CategoryNameMatcher.Candidate(id: 1, name: "Groceries"),
            CategoryNameMatcher.Candidate(id: 2, name: "Transport"),
            CategoryNameMatcher.Candidate(id: 3, name: "Nightlife"),
        ]
        let theirs = [
            CategoryNameMatcher.Candidate(id: 10, name: "Grocery"),
            CategoryNameMatcher.Candidate(id: 11, name: "Transportation"),
            CategoryNameMatcher.Candidate(id: 12, name: "Insurance"),
        ]

        let matches = CategoryNameMatcher.pair(mine: mine, theirs: theirs)

        #expect(matches.count == 2)
        #expect(matches.allSatisfy { $0.score >= CategoryNameMatcher.threshold })
    }
}
