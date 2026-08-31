import KeepoCore
import SwiftUI

/// The user's face, wherever it appears — the scope banner's tap target
/// into Profile, and Profile's own header. One view so the two can't drift
/// apart the day a real uploaded photo replaces the initial.
struct ProfileAvatarView: View {
    let email: String?
    var size: CGFloat = 40
    /// Drawn on a saturated gradient card (`onColor: true`) or on the app's
    /// own neutral surface. Only the two fill/foreground colours differ, so
    /// this is a flag rather than two views.
    var onColor = false

    var body: some View {
        ZStack {
            Circle().fill(onColor ? Color.white.opacity(0.25) : Color.primary.opacity(0.12))
            Text(initial)
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(onColor ? Color.white : Color.primary)
        }
        .frame(width: size, height: size)
        .overlay {
            if onColor {
                Circle().strokeBorder(Color.white.opacity(0.45), lineWidth: 1)
            }
        }
    }

    private var initial: String {
        String((email ?? "?").prefix(1)).uppercased()
    }
}
