import KeepoCore
import SwiftUI

/// The avatar, as a thing you can change.
///
/// Lifted out of `ProfileView.identity` because onboarding's first step
/// draws exactly this — same circle, same camera badge, same busy state —
/// and two copies would drift the moment either screen was touched.
///
/// The camera glyph is an **overlay hanging beside** the circle rather than
/// a sibling in a stack, which is the decision worth keeping: a camera
/// button laid out next to an avatar reads as a second control, while one
/// attached to its edge reads as this one's verb.
struct AvatarButton: View {
    let name: String?
    let email: String?
    let image: UIImage?
    /// Suppresses the badge and the tap while an upload is in flight, so
    /// the control cannot be fired twice.
    var isBusy = false
    var size: CGFloat = AppTheme.Size.illustration
    /// Passed through to `ProfileAvatarView`.
    var placeholder = ProfileAvatarView.Placeholder.initial
    /// Off where the placeholder is itself the "add a photo" mark, which
    /// makes a camera beside it say the same thing twice.
    var showsCameraBadge = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ProfileAvatarView(name: name, email: email, image: image, size: size, placeholder: placeholder)
                .overlay(alignment: .bottomTrailing) {
                    Group {
                        if isBusy {
                            ProgressView()
                        } else if showsCameraBadge {
                            KeepoIcon(name: "icon-camera", size: badgeDiameter / 2)
                                .foregroundStyle(AppTheme.Palette.textPrimary)
                        }
                    }
                    .frame(width: badgeDiameter, height: badgeDiameter)
                    .offset(x: badgeDiameter * 0.9)
                }
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityLabel(image == nil ? "Add a profile photo" : "Change profile photo")
    }

    /// The camera sits **beside** the circle, bottom-aligned, with no disc
    /// behind it: nothing overlaps the avatar, so nothing has to keep it
    /// legible over a photograph, and it reads as this control's verb
    /// rather than a sticker on the picture.
    ///
    /// Sized as a fraction of the avatar rather than a fixed token, so it
    /// still reads as a camera on a hero-sized one instead of shrinking to
    /// a speck beside it. The overlay hangs outside the avatar's frame, so
    /// it takes no layout space.
    private var badgeDiameter: CGFloat { size * 0.4 }
}
