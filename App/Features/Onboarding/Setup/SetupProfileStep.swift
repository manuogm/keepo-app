import KeepoCore
import SwiftUI
import UIKit

/// Step 1 — a name and a photo, neither of which Keepo needs and both of
/// which change what it feels like to open.
///
/// **Nothing here reaches the server.** The photo is downscaled to the same
/// 512px JPEG `AvatarStore` would have uploaded and parked in the draft;
/// the name sits beside it. Both are written at the commit, which is why
/// abandoning setup on this screen leaves no half-made profile behind.
///
/// The name field is **prefilled and never accepted silently**.
/// `DisplayNameSuggestion` refuses anything that does not read like a first
/// name, so most of the time this is empty — and when it is not, Next is
/// the user agreeing with it. Skip is the user declining, which is why Skip
/// clears the field rather than keeping the guess.
struct SetupProfileStep: View {
    let session: SessionStore
    let store: OnboardingDraftStore

    /// `profiles_display_name_length` allows 1–60 characters after
    /// trimming. Capped here so the constraint is never the error message.
    private static let nameLimit = 60

    @State private var name = ""
    @State private var image: UIImage?
    @State private var isPickingAvatar = false
    @FocusState private var isEditingName: Bool

    var body: some View {
        OnboardingScaffold(
            title: "Your profile",
            subtitle: "The name Keepo greets you with. Both this and your photo are editable any time.",
            step: .profile,
            onSkip: skip,
            isPrimaryEnabled: true,
            onPrimary: next
        ) {
            VStack(spacing: AppTheme.Spacing.xl) {
                AvatarButton(
                    name: trimmedName.isEmpty ? nil : trimmedName,
                    email: session.userEmail,
                    image: image
                ) {
                    isEditingName = false
                    isPickingAvatar = true
                }

                TextField("Your name", text: $name)
                    .font(AppTheme.Typography.body)
                    .textContentType(.givenName)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.continue)
                    .focused($isEditingName)
                    .onSubmit(next)
                    .padding(AppTheme.Spacing.m)
                    .background(
                        AppTheme.Palette.bgSurface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.control)
                    )
                    .onChange(of: name) { _, typed in
                        guard typed.count > Self.nameLimit else { return }
                        name = String(typed.prefix(Self.nameLimit))
                    }
            }
            .frame(maxWidth: .infinity)
        }
        .avatarPicker(
            isPresentingOptions: $isPickingAvatar,
            canRemove: image != nil,
            onPicked: pick(_:),
            onRemove: removePhoto
        )
        .task {
            name = store.draft.displayName
                ?? DisplayNameSuggestion.suggestion(from: nil, email: session.userEmail)
                ?? ""
            if let data = store.draft.avatarJPEG { image = UIImage(data: data) }
        }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Downscaled the instant it is picked rather than at the commit, for
    /// two reasons: the draft is persisted on every change, and a full
    /// camera capture in `UserDefaults` is not a thing to do to anyone; and
    /// the picture the user is now looking at should be the one that gets
    /// uploaded, cropping included.
    private func pick(_ picked: UIImage) {
        guard let jpeg = AvatarStore.downscaledJPEG(picked) else { return }
        image = UIImage(data: jpeg)
        store.update { $0.avatarJPEG = jpeg }
    }

    private func removePhoto() {
        image = nil
        store.update { $0.avatarJPEG = nil }
    }

    /// An empty field is `nil`, not `""` — the column's CHECK refuses the
    /// empty string, and "no name" is genuinely absence.
    private func next() {
        store.update { $0.displayName = trimmedName.isEmpty ? nil : trimmedName }
        store.advance()
    }

    /// Skip means what the plan says it means on this step: no name, no
    /// photo. Keeping a prefilled suggestion through a Skip would be
    /// accepting a guess on the user's behalf, which is the one thing
    /// `DisplayNameSuggestion` exists to prevent.
    private func skip() {
        store.update {
            $0.displayName = nil
            $0.avatarJPEG = nil
        }
        store.advance()
    }
}
