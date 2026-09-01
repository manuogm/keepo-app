import KeepoCore
import SwiftUI

/// The user's face, wherever it appears — the scope banner's tap target
/// into Profile, and Profile's own header. One view so the two can't drift
/// apart the day a real uploaded photo replaces the initial.
struct ProfileAvatarView: View {
    let email: String?
    var size = AppTheme.Size.icon
    /// Drawn on a saturated gradient card (`onColor: true`) or on the app's
    /// own neutral surface. Only the two fill/foreground colours differ, so
    /// this is a flag rather than two views.
    var onColor = false

    var body: some View {
        ZStack {
            Circle().fill(
                onColor
                    ? AppTheme.Palette.textOnAccent.opacity(AppTheme.Opacity.fillStrong)
                    : AppTheme.Palette.textPrimary.opacity(AppTheme.Opacity.fill)
            )
            Text(initial)
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(onColor ? AppTheme.Palette.textOnAccent : AppTheme.Palette.textPrimary)
        }
        .frame(width: size, height: size)
        .overlay {
            if onColor {
                Circle().strokeBorder(AppTheme.Palette.textOnAccent.opacity(AppTheme.Opacity.muted), lineWidth: 1)
            }
        }
    }

    private var initial: String {
        String((email ?? "?").prefix(1)).uppercased()
    }
}
