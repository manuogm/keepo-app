import Foundation

/// Which of two people's categories mean the same thing.
///
/// Two users who have kept their own books for years arrive at a household
/// with "Dine Out" and "Dining Out", "Transport" and "Transportation",
/// "Groceries" and "Grocery". `ensure_category_twin` in SQL matches on
/// trimmed, lowercased equality, which catches "Groceries"/"groceries" and
/// nothing else — so without this every near-miss becomes two rows that look
/// identical in both members' pickers, forever.
///
/// It lives here, in `KeepoCore`, for the reason CLAUDE.md gives: it is pure
/// logic over strings, and the only way to know a similarity threshold is
/// right is to pin real pairs against it in a test. The **applying** of a
/// match is still SQL — `apply_category_merges` — because that is where
/// ownership and the one-row-per-member invariant are enforced.
///
/// ## Deliberately generous
///
/// The threshold is tuned to over-suggest rather than to miss, and that is a
/// judgement about which mistake costs more. A missed match is two duplicate
/// categories the user has to find and merge by hand, and will probably
/// never bother to. A false match is one row in the report's "Merged" list,
/// labelled with the robot glyph as automatic, one tap from being unmerged
/// before the household even finishes being built. The report exists to be
/// reviewed; the matcher's job is to make sure there is something to review.
public enum CategoryNameMatcher {
    /// Above this, two names are proposed as the same category.
    ///
    /// 0.72 is the value that admits "Dine Out"/"Dining Out" — the weakest
    /// pair worth merging on spelling alone — while rejecting
    /// "Travel"/"Transport" (0.33). "Food"/"Fuel", "Health"/"Wealth" and
    /// "Salary"/"Solar" never reach the threshold at all: they are stopped
    /// earlier, by `gatedEditRatio`. Every one of those pairs is pinned in
    /// `CategoryNameMatcherTests`, so moving this number tells you exactly
    /// which two categories you just changed your mind about.
    ///
    /// It is deliberately not the only thing standing between two names and
    /// a merge. Pairs that mean the same thing and share no spelling —
    /// "Eating Out"/"Dining Out", "Home"/"House" — are settled by
    /// `conceptLexicon` before any arithmetic happens, and arrive here as
    /// exact matches. No threshold could have found them.
    public static let threshold: Double = 0.72

    /// A proposed pairing, strongest first.
    public struct Match<ID: Hashable>: Hashable, Sendable where ID: Sendable {
        public let mine: ID
        public let theirs: ID
        public let score: Double

        public init(mine: ID, theirs: ID, score: Double) {
            self.mine = mine
            self.theirs = theirs
            self.score = score
        }
    }

    /// One side's category, reduced to what matching actually needs.
    public struct Candidate<ID: Hashable>: Sendable, Hashable where ID: Sendable {
        public let id: ID
        public let name: String

        public init(id: ID, name: String) {
            self.id = id
            self.name = name
        }
    }

    // MARK: - Pairing

    /// The best one-to-one pairing between two people's categories.
    ///
    /// **One-to-one, greedily by descending score.** A category can only be
    /// merged into one other category — the shared-group invariant is one row
    /// per member — so once "Dining Out" has claimed "Dine Out", neither is
    /// available to "Eating Out" even if that would also have scored above
    /// the threshold. Greedy rather than optimal (Hungarian) on purpose: the
    /// lists are a few dozen rows, the scores are heuristic to begin with, and
    /// a globally-optimal pairing over fuzzy scores would be harder to
    /// explain to the user than the result is worth.
    ///
    /// Ties break on `mine` then `theirs` so the same two lists always
    /// produce the same pairing — an unstable auto-merge would mean two
    /// phones narrating a different household to each other.
    public static func pair<ID: Hashable & Sendable & Comparable>(
        mine: [Candidate<ID>], theirs: [Candidate<ID>]
    ) -> [Match<ID>] {
        var scored: [Match<ID>] = []
        for candidate in mine {
            for other in theirs {
                let score = similarity(candidate.name, other.name)
                guard score >= threshold else { continue }
                scored.append(Match(mine: candidate.id, theirs: other.id, score: score))
            }
        }

        scored.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.mine != $1.mine { return $0.mine < $1.mine }
            return $0.theirs < $1.theirs
        }

        var takenMine: Set<ID> = []
        var takenTheirs: Set<ID> = []
        var result: [Match<ID>] = []
        for match in scored {
            guard !takenMine.contains(match.mine), !takenTheirs.contains(match.theirs) else { continue }
            takenMine.insert(match.mine)
            takenTheirs.insert(match.theirs)
            result.append(match)
        }
        return result
    }

    // MARK: - Scoring

    /// How alike two category names are, in 0...1.
    ///
    /// The maximum of two readings rather than a blend, because they catch
    /// different failures and a blend would dilute both. **Whole-string**
    /// edit distance catches a typo or an inflection spread across the name;
    /// **per-token** pairing catches a name that is the same words with one
    /// of them inflected ("Dine Out" / "Dining Out"), where the shared token
    /// carries most of the meaning and whole-string distance under-reads it.
    public static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let mine = concepts(lhs)
        let theirs = concepts(rhs)

        guard !mine.isEmpty, !theirs.isEmpty else { return 0 }
        if mine == theirs { return 1 }
        // Same words in a different order — "Out Dining" is not a different
        // category from "Dining Out". Just short of 1 so a genuine exact
        // match always outranks it in the greedy pairing above.
        if mine.sorted() == theirs.sorted() { return 0.98 }

        return max(
            gatedEditRatio(mine.joined(separator: " "), theirs.joined(separator: " ")),
            tokenRatio(mine, theirs)
        )
    }

    /// Edit distance, but only for words that agree on how they start.
    ///
    /// Without this gate the matcher confidently merges **Health** with
    /// **Wealth**: one substitution across six letters reads as 0.83 alike,
    /// higher than "Dine Out"/"Dining Out" scores, so no threshold can
    /// separate them. Edit distance has no notion of *where* a difference
    /// falls, and for a category name the position is the whole signal — a
    /// difference at the end is an inflection (Rent/Rental,
    /// Transport/Transportation), a difference at the start is a different
    /// word (Food/Fuel, Salary/Solar, Gifts/Gas).
    ///
    /// Two shared leading characters, because one is not evidence of
    /// anything: a fifth of the alphabet's common words start with the same
    /// letter as any given one.
    ///
    /// The cost of the gate is that a genuine synonym pair sharing no
    /// opening — "Eating Out" and "Dining Out" — cannot be found by
    /// arithmetic at all. That is still the correct outcome here: nothing
    /// about those two *strings* says they are the same category, and the
    /// pass they would otherwise get comes from the same arithmetic that
    /// passes Health/Wealth. Meaning is not spelling, so it is answered
    /// before this runs, by `conceptLexicon`.
    private static func gatedEditRatio(_ lhs: String, _ rhs: String) -> Double {
        guard commonPrefixLength(lhs, rhs) >= 2 else { return 0 }
        return editRatio(lhs, rhs)
    }

    private static func commonPrefixLength(_ lhs: String, _ rhs: String) -> Int {
        zip(lhs, rhs).prefix { $0 == $1 }.count
    }

    /// The average, over the shorter list, of each token's best partner in
    /// the longer one. Taken from the shorter side so that a two-word name
    /// is not punished for meeting a four-word one — "Transport" against
    /// "Public Transport Costs" should read as a strong partial match, not a
    /// weak one.
    private static func tokenRatio(_ mine: [String], _ theirs: [String]) -> Double {
        let (shorter, longer) = mine.count <= theirs.count ? (mine, theirs) : (theirs, mine)
        guard !shorter.isEmpty else { return 0 }
        let total = shorter.reduce(0.0) { running, token in
            running + (longer.map { tokenSimilarity(token, $0) }.max() ?? 0)
        }
        return total / Double(shorter.count)
    }

    /// One word against one word.
    ///
    /// The prefix rule is what makes "Transport"/"Transportation" and
    /// "Rent"/"Rental" land, where edit distance reads them as barely half
    /// alike because it counts every trailing character as a difference. It
    /// needs **four** shared leading characters before it applies: at three,
    /// "Car" would claim "Care", and at two almost everything claims
    /// everything.
    private static func tokenSimilarity(_ lhs: String, _ rhs: String) -> Double {
        if lhs == rhs { return 1 }
        if min(lhs.count, rhs.count) >= 4, lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs) { return 0.92 }
        return gatedEditRatio(lhs, rhs)
    }

    /// Levenshtein distance as a similarity in 0...1.
    private static func editRatio(_ lhs: String, _ rhs: String) -> Double {
        let longest = max(lhs.count, rhs.count)
        guard longest > 0 else { return 1 }
        return 1 - (Double(levenshtein(Array(lhs), Array(rhs))) / Double(longest))
    }

    /// Two rows rather than a full matrix — the distance for row `i` only
    /// ever reads row `i - 1`, and these are category names, but the shape
    /// costs nothing and means a pathologically long name cannot allocate a
    /// large square.
    private static func levenshtein(_ lhs: [Character], _ rhs: [Character]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }

        var previous = Array(0...rhs.count)
        var current = [Int](repeating: 0, count: rhs.count + 1)

        for row in 1...lhs.count {
            current[0] = row
            for column in 1...rhs.count {
                let substitution = previous[column - 1] + (lhs[row - 1] == rhs[column - 1] ? 0 : 1)
                current[column] = min(previous[column] + 1, current[column - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[rhs.count]
    }

    // MARK: - Normalization

    /// Noise words that carry no identity of their own. "Food & Drink" and
    /// "Food and Drink" are one category; so are "The Car" and "Car".
    private static let ignoredTokens: Set<String> = ["and", "the", "a", "of", "my", "our"]

    /// A name reduced to the **concepts** it names, which is what matching
    /// actually compares.
    ///
    /// `normalize` settles spelling; this settles meaning, and they are
    /// separate steps because they fail differently. Everything below the
    /// gate in this file is arithmetic over characters, and arithmetic can
    /// never learn that "Eating Out" and "Dining Out" are one category —
    /// they share no opening, so `gatedEditRatio` scores them 0, and the only
    /// threshold low enough to admit them also admits Health/Wealth. That is
    /// not a tuning problem, it is a missing input.
    ///
    /// So the missing input is supplied directly. Nothing here is inferred:
    /// each entry is a word two people plausibly used for the same line in
    /// their own books, and a pair that collapses onto one concept scores an
    /// exact 1.0 rather than squeaking past a threshold.
    static func concepts(_ name: String) -> [String] {
        normalize(name).map { conceptLexicon[$0] ?? $0 }
    }

    /// Words that name the same thing, mapped onto one of them.
    ///
    /// Keys are **singularized** forms, because this runs after
    /// `singularize` — "Groceries" arrives as "grocery", "Holidays" as
    /// "holiday". Values are canonical only in the sense that they are equal
    /// to each other; which word won is arbitrary and never shown to anybody,
    /// since the merge's resultant name comes from the row the owner pointed
    /// at, not from here.
    ///
    /// ## What is deliberately absent
    ///
    /// **Ambiguous words.** "Food" means groceries to one person and eating
    /// out to another, and "Gas" is a car in one country and a boiler in the
    /// next. Mapping either one picks a side and produces a confidently
    /// wrong merge, which is a worse failure than the near-miss this file
    /// exists to fix — the merged pair is what the household then files
    /// against. When a word genuinely has two meanings it is left alone and
    /// the fuzzy scorer treats it as its own concept.
    ///
    /// **Anything needing a dictionary.** No stemming, no embeddings, no
    /// network. This is a few dozen finance words, it works offline and
    /// identically on both phones, and its whole behaviour is readable in one
    /// screen — which matters, because two phones disagreeing about what
    /// merged would be a household narrating itself differently to each
    /// member.
    private static let conceptLexicon: [String: String] = [
        "dine": "dining", "dining": "dining", "restaurant": "dining",
        "eatery": "dining", "eating": "dining", "eat": "dining",
        "takeaway": "dining", "takeout": "dining",

        "grocery": "grocery", "supermarket": "grocery",

        "transport": "transport", "transportation": "transport",
        "transit": "transport", "commute": "transport", "commuting": "transport",
        "fare": "transport",

        "fuel": "fuel", "petrol": "fuel", "gasoline": "fuel", "diesel": "fuel",

        "car": "car", "auto": "car", "automobile": "car", "vehicle": "car",

        "utility": "utility", "bill": "utility",

        "home": "home", "house": "home", "household": "home", "housing": "home",

        "health": "health", "healthcare": "health", "medical": "health", "doctor": "health",

        "fitness": "fitness", "gym": "fitness", "workout": "fitness",

        "entertainment": "entertainment", "leisure": "entertainment", "hobby": "entertainment",

        "subscription": "subscription", "streaming": "subscription", "membership": "subscription",

        "shopping": "shopping", "shop": "shopping", "retail": "shopping",

        "travel": "travel", "trip": "travel", "holiday": "travel", "vacation": "travel",

        "salary": "salary", "wage": "salary", "paycheck": "salary",
        "payroll": "salary", "payslip": "salary",

        "investment": "investment", "investing": "investment",

        "gift": "gift", "present": "gift",

        "child": "child", "children": "child", "kid": "child", "childcare": "child",

        "education": "education", "school": "education", "tuition": "education", "study": "education",

        "coffee": "coffee", "cafe": "coffee",

        "drink": "drink", "bar": "drink", "pub": "drink", "alcohol": "drink",

        "phone": "phone", "mobile": "phone", "telephone": "phone",

        "internet": "internet", "broadband": "internet", "wifi": "internet"
    ]

    /// A name reduced to its comparable words: lowercased, stripped of
    /// punctuation and diacritics, split, de-noised and singularized.
    ///
    /// Singularization is the highest-value step in here by a wide margin,
    /// because the single commonest real collision between two people's
    /// books is a plural disagreement — Groceries/Grocery, Salaries/Salary,
    /// Holidays/Holiday, Utilities/Utility. All four become exact matches,
    /// scoring 1.0, rather than fuzzy ones scoring near the threshold.
    static func normalize(_ name: String) -> [String] {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let cleaned = folded.map { character -> Character in
            character.isLetter || character.isNumber ? character : " "
        }
        let tokens = String(cleaned)
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !ignoredTokens.contains($0) }
            .map(singularize)

        // A name made entirely of noise words is still that name — "The
        // Other" must not normalize to nothing and then match everything.
        return tokens.isEmpty
            ? String(cleaned).split(separator: " ").map(String.init)
            : tokens
    }

    /// English plurals, to the depth a category name ever reaches.
    ///
    /// Not a stemmer. Porter would turn "dining" into "dine" and make one of
    /// this matcher's headline cases exact — and would also turn "savings"
    /// into "save" and "utilities" into "util", collapsing distinctions the
    /// user made on purpose. The three rules below are the ones that are
    /// safe without a dictionary; anything past them is the fuzzy scorer's
    /// job.
    private static func singularize(_ token: String) -> String {
        // Groceries → Grocery, Utilities → Utility, Salaries → Salary. The
        // commonest of the four real collisions, and the only one that needs
        // a letter put back.
        if token.count > 4, token.hasSuffix("ies") {
            return String(token.dropLast(3)) + "y"
        }
        // "ss" is not a plural — Fitness must not become Fitnes.
        guard token.count > 3, token.hasSuffix("s"), !token.hasSuffix("ss") else { return token }
        // Whole "es" comes off only after the letters that actually take it:
        // Boxes → Box, Watches → Watch, Dishes → Dish. Everywhere else it is
        // a bare "s" on a word that already ended in "e", and dropping both
        // would turn Expenses into "Expens" — which then fails to match the
        // other member's "Expense", the exact collision this is here to fix.
        let stem = String(token.dropLast(2))
        if token.hasSuffix("es"), stem.hasSuffix("x") || stem.hasSuffix("z")
            || stem.hasSuffix("ch") || stem.hasSuffix("sh") {
            return stem
        }
        return String(token.dropLast())
    }
}
