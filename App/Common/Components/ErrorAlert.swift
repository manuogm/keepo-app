import KeepoCore
import SwiftUI

/// What a failed *action* does, everywhere in the app: interrupt, name what
/// failed, and say what to do about it.
///
/// This replaces the pattern the settings screens used to share — an
/// `errorMessage` string rendered as a `FormErrorText` somewhere in the
/// view's own layout — which fails in exactly the situation that matters
/// most. Profile's error label lived in the *header* section at the top of a
/// long `List`; Delete Account is the last row at the bottom. Every deletion
/// failure wrote its explanation several hundred points above where the user
/// was looking, so a biometric refusal and a button that had never been
/// wired up were indistinguishable from the seat of the person tapping it.
/// (`FormErrorText` itself had shipped a `body` that returned itself —
/// infinite recursion — for a month before anyone noticed, for the same
/// underlying reason: an inline error is the one view a screen almost never
/// draws.)
///
/// Inline text is still right for **validation** — a field that is wrong
/// while you are looking straight at it, and that needs no dismissing. This
/// is for the other kind: work that was asked for and did not happen.
struct ActionError {
    /// Names the action that failed, not the failure — "Couldn't Delete
    /// Account". The message carries the why, and an alert whose title is
    /// also the why says the same thing twice.
    let title: String
    let message: String

    /// The only way to build one from a thrown error, so no call site can
    /// put a raw `error` in front of a user: the text always comes from
    /// `UserFacingError.describe`.
    ///
    /// **Fails on cancellation**, which is the point of it being failable.
    /// Dismissing a Face ID sheet or a passcode prompt is an instruction to
    /// stop, not a failure to report, and an alert answering it reads as a
    /// bug. Assigning the result straight into the alert's own optional
    /// state means a cancel quietly clears it instead of shouting.
    init?(_ title: String, _ error: Error) {
        guard !UserFacingError.isCancellation(error) else { return nil }
        self.title = title
        self.message = UserFacingError.describe(error)
    }

    /// For the failures that never were an `Error` — a guard that found no
    /// signed-in user, an image that could not be read.
    init(title: String, message: String) {
        self.title = title
        self.message = message
    }
}

extension View {
    /// Presents `error` as an alert, and clears it when the user dismisses.
    func errorAlert(_ error: Binding<ActionError?>) -> some View {
        modifier(ErrorAlertModifier(error: error))
    }
}

private struct ErrorAlertModifier: ViewModifier {
    @Binding var error: ActionError?

    func body(content: Content) -> some View {
        content.alert(
            error?.title ?? "",
            isPresented: Binding(
                get: { error != nil },
                set: { isPresented in if !isPresented { error = nil } }
            ),
            presenting: error
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error.message)
        }
    }
}
