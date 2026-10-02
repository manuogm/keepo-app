import Foundation

/// Whether text is shaped like an email address — sign-in's check before it
/// asks Supabase to send a link.
///
/// **A shape check, not a validator.** The only real test of an address is
/// whether mail reaches it, and the magic link is that test. This exists to
/// turn away the typo the user can see and fix on the spot — a missing `@`,
/// a domain with no dot, a stray space — instead of spending a round trip
/// and a "Check your email" screen on an address that was never going to
/// work. So it errs permissive: anything plausible passes, because refusing
/// a real address locks someone out of the app, and letting a bad one
/// through only costs them a link that never arrives.
public enum EmailAddress {
    /// `local@domain.tld`: one `@`, nothing empty on either side of it, no
    /// whitespace, and a domain of dot-separated labels ending in a
    /// top-level domain of at least two letters. Surrounding whitespace is
    /// ignored, since the field trims it before sending anyway.
    public static func isPlausible(_ text: String) -> Bool {
        let address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.contains(where: \.isWhitespace) else { return false }
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        let labels = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return false }
        let topLevel = labels[labels.count - 1]
        return topLevel.count >= 2 && topLevel.allSatisfy(\.isLetter)
    }
}
