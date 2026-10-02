import Foundation

/// One line for the launch splash (`RootLoadingView`) — a nudge toward the
/// tracking habit, or toward what having money under control buys.
///
/// Every quote carries its author, and an addition should only go in when
/// the attribution traces to the person's own words: popular money quotes
/// are misattributed more often than not, and a finance app quoting
/// someone who never said it is a small lie on the first screen.
struct LaunchQuote: Equatable {
    let text: String
    let author: String

    /// Picked once per process — a `static let` is evaluated lazily and
    /// exactly once — so the quote cannot change under the user if the
    /// splash re-renders, and is never the one the previous launch showed.
    static let forThisLaunch: LaunchQuote = {
        let defaults = UserDefaults.standard
        let last = defaults.string(forKey: AppSettingsKeys.lastLaunchQuote)
        let candidates = all.filter { $0.text != last }
        // `all` is a non-empty literal, so this only falls back if it is
        // ever cut to a single quote — which then shows every launch.
        let quote = candidates.randomElement() ?? all[0]
        defaults.set(quote.text, forKey: AppSettingsKeys.lastLaunchQuote)
        return quote
    }()

    static let all: [LaunchQuote] = [
        LaunchQuote(
            text: "Beware of little expenses. A small leak will sink a great ship.",
            author: "Benjamin Franklin"
        ),
        LaunchQuote(
            text: "It is not the man who has too little, but the man who craves more, that is poor.",
            author: "Seneca"
        ),
        LaunchQuote(
            text: "That man is the richest whose pleasures are the cheapest.",
            author: "Henry David Thoreau"
        ),
        LaunchQuote(
            text: "You must gain control over your money or the lack of it will forever control you.",
            author: "Dave Ramsey"
        ),
        LaunchQuote(
            text: "Being rich is having money; being wealthy is having time.",
            author: "Margaret Bonanno"
        ),
        LaunchQuote(
            text: "The goal isn't more money. The goal is living life on your terms.",
            author: "Chris Brogan"
        ),
        LaunchQuote(
            text: "Motivation is what gets you started. Habit is what keeps you going.",
            author: "Jim Ryun"
        ),
        LaunchQuote(
            text: "All big things come from small beginnings. The seed of every habit is a single, tiny decision.",
            author: "James Clear"
        ),
        LaunchQuote(
            text: "You do not rise to the level of your goals. You fall to the level of your systems.",
            author: "James Clear"
        )
    ]
}
