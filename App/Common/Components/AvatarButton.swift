import KeepoCore
import SwiftUI

/// The avatar, as a thing you can change.
///
/// Lifted out of `ProfileView.identity` because onboarding's first step
/// draws exactly this — same circle, same camera badge, same busy state —
/// and two copies would drift the moment either screen was touched.
///
/// The camera badge is **overlaid rather than placed beside** the circle,
/// which is the decision worth keeping: a camera button next to an avatar
/// reads as a second control, while one sitting on its corner reads as this
/// one's verb.
struct AvatarButton: View {
    let name: String?
    let email: String?
    let image: UIImage?
    /// Suppresses the badge and the tap while an upload is in flight, so
    /// the control cannot be fired twice.
    var isBusy = false
    var size: CGFloat = AppTheme.Size.illustration
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ProfileAvatarView(name: name, email: email, image: image, size: size)
                .overlay(alignment: .bottomTrailing) {
                    if isBusy {
                        ProgressView()
                    } else {
                        badge
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityLabel(image == nil ? "Add a profile photo" : "Change profile photo")
    }

    /// The white disc and its canvas-coloured ring are what keep the badge
    /// legible over a photograph of anything at all.
    private var badge: some View {
        KeepoIcon(name: "icon-camera", size: AppTheme.Size.glyphSmall)
            .foregroundStyle(AppTheme.Palette.textPrimary)
            .frame(width: AppTheme.Size.icon, height: AppTheme.Size.icon)
            .background(AppTheme.Palette.textOnAccent, in: Circle())
            .overlay(Circle().strokeBorder(AppTheme.Palette.bgCanvas, lineWidth: 2))
            .offset(x: 8, y: 8)
    }
}
