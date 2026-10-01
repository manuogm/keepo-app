import SwiftUI
import UIKit

/// A tap on the canvas around a field puts the keyboard away.
///
/// iOS gives a keyboard exactly one guaranteed exit — the return key — and
/// onboarding has two fields without one. The name field's return is
/// `.continue`, which submits rather than dismisses; the opening balance
/// uses a decimal pad, which has **no return key at all**. So on the
/// account step the keyboard could be raised and never lowered: it covered
/// the forward button, and the only gesture that would have closed it,
/// `scrollDismissesKeyboard(.interactively)`, needs a drag on content that
/// is usually too short to scroll.
///
/// **On the container, not as an overlay.** A transparent catcher laid over
/// a screen eats the first tap on everything beneath it — the classic
/// version of this trick, and the reason it gets ripped out again. A tap
/// gesture on the *container* is resolved innermost-first, so a button, a
/// field or a picker row under the finger still wins its own tap and only
/// the ones nothing else wanted arrive here.
extension View {
    func dismissesKeyboardOnTap() -> some View {
        contentShape(Rectangle())
            .onTapGesture {
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
                )
            }
    }
}
