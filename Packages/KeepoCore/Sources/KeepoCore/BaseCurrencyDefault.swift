import Foundation

/// Which currency the base-currency step should already be sitting on.
///
/// The flow this replaces hardcoded `"USD"`, which is a fine default for
/// roughly one country and a poor first impression everywhere else — in an
/// app whose third feature screen sells multi-currency, it is the first
/// thing a non-US user is asked to correct.
///
/// **A suggestion, never a decision.** The wheel is right there and the
/// user spins it if this is wrong. What this buys is that for most people
/// it is not wrong, so the step's Skip ("yes, that one") is honest rather
/// than a coin flip.
///
/// Restricted to the currencies Keepo actually supports — the ECB/
/// Frankfurter set, which is what `currencies` holds — because a base
/// currency outside it has no FX rates, and every balance in the app would
/// render `—` forever.
public enum BaseCurrencyDefault {
    /// The fallback's fallback: the locale offered nothing usable *and* the
    /// supported set somehow does not contain USD.
    private static let anchor = "USD"

    /// - Parameter supported: the codes in `currencies`. Empty only before
    ///   the first sync has landed, in which case the step is still showing
    ///   its spinner and this answer is never seen.
    public static func suggestion(supported: [String], locale: Locale = .current) -> String {
        let codes = supported.map { $0.uppercased() }
        guard let local = locale.currency?.identifier.uppercased(), codes.contains(local) else {
            return fallback(in: codes)
        }
        return local
    }

    /// USD when it is there — it is the one currency in the set with a rate
    /// against everything else, so it is the least surprising thing to be
    /// pointing at — and otherwise the first code alphabetically, so the
    /// wheel is at least sitting on a row that exists.
    private static func fallback(in codes: [String]) -> String {
        codes.contains(anchor) ? anchor : (codes.sorted().first ?? anchor)
    }
}
