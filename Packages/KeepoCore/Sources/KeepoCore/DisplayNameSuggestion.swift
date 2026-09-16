import Foundation

/// What to prefill the onboarding name field with, when anything can be
/// said honestly — and `nil` the rest of the time.
///
/// **The rule this type exists to keep: a wrong name is worse than no
/// name.** `OnboardingView` carried that decision as a comment refusing to
/// split a name out of an email at all, and it was right about the example
/// in front of it: `fam.samper.ona` is not what anyone calls themselves.
/// This is the same refusal, made testable and given somewhere for a real
/// identity to arrive later.
///
/// **The seam is the point.** Sign-in with Apple (Phase 20) hands back
/// `PersonNameComponents` — but only on the *first* authorization, so it is
/// captured then or never. When it lands it flows in here and the email
/// heuristic becomes the fallback it was always meant to be, with no call
/// site changing.
public enum DisplayNameSuggestion {
    /// - Parameter components: from Sign in with Apple, when there is one.
    ///   A real identity beats any guess, so it is checked first.
    /// - Parameter email: the address the user signed in with. Only its
    ///   local part is ever looked at, and only when it reads like a name.
    /// - Returns: a name to **prefill, editable** — never to accept
    ///   silently — or `nil`, which the field shows as "Add your name".
    public static func suggestion(from components: PersonNameComponents?, email: String?) -> String? {
        if let given = components?.givenName?.trimmingCharacters(in: .whitespaces), !given.isEmpty {
            return given
        }
        if let nickname = components?.nickname?.trimmingCharacters(in: .whitespaces), !nickname.isEmpty {
            return nickname
        }
        return fromEmail(email)
    }

    /// Four refusals, each for a shape that is reliably **not** a first
    /// name:
    ///
    /// 1. **Digits** — `manu92`, `user123`. A name does not carry a number.
    /// 2. **Under three characters** — `jl`, `m`. Too little to be a name
    ///    and too easy to be initials.
    /// 3. **Three or more segments** — `fam.samper.ona`. This is a full
    ///    name written as an address, and picking any one piece of it gets
    ///    the person's name wrong.
    /// 4. **A role address** — `info`, `hello`, `noreply`. A mailbox, not a
    ///    person. Not in the original three rules; added because it is the
    ///    same principle and the failure is the same kind of wrong.
    ///
    /// Otherwise the **first** segment is the suggestion — `manu.ogm` is
    /// Manu — and it must itself be three characters or more, so `j.smith`
    /// yields nothing rather than "J".
    private static func fromEmail(_ email: String?) -> String? {
        guard let email, let localPart = email.split(separator: "@").first.map(String.init) else { return nil }
        let local = localPart.trimmingCharacters(in: .whitespaces).lowercased()

        guard local.count >= 3, !local.contains(where: \.isNumber), !roleAddresses.contains(local) else { return nil }

        let segments = local.split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" })
        guard segments.count <= 2, let first = segments.first, first.count >= 3 else { return nil }
        return String(first).capitalized
    }

    private static let roleAddresses: Set<String> = [
        "info", "hello", "hi", "contact", "admin", "support", "noreply", "no-reply", "mail", "email",
        "me", "team", "office", "sales", "help", "billing", "accounts", "post", "inbox"
    ]
}
