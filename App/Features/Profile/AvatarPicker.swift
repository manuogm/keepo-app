import PhotosUI
import SwiftUI
import UIKit

/// The two ways a picture gets in, plus the way it gets out again.
///
/// Two different mechanisms behind one menu, because iOS has no single one:
/// `PhotosPicker` runs out of process and needs no permission at all (the
/// user picking a photo *is* the grant, which is why there is no
/// `NSPhotoLibraryUsageDescription` anywhere in this project), while the
/// camera is `UIImagePickerController` in a representable and does need
/// `NSCameraUsageDescription`.
///
/// A `confirmationDialog` rather than a menu on the avatar: the choices are
/// two sources and one destructive action, and the destructive one has to be
/// visibly separate from the other two rather than a third item that looks
/// like them.
struct AvatarPickerModifier: ViewModifier {
    @Binding var isPresentingOptions: Bool
    let canRemove: Bool
    let onPicked: (UIImage) -> Void
    let onRemove: () -> Void

    @State private var photoItem: PhotosPickerItem?
    @State private var isShowingLibrary = false
    @State private var isShowingCamera = false

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Profile photo", isPresented: $isPresentingOptions, titleVisibility: .hidden) {
                // Offered only where there is a camera. On a device without
                // one the button exists, opens nothing, and looks broken.
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button("Take Photo") { isShowingCamera = true }
                }
                Button("Choose from Library") { isShowingLibrary = true }
                if canRemove {
                    Button("Remove Photo", role: .destructive, action: onRemove)
                }
                Button("Cancel", role: .cancel) {}
            }
            .photosPicker(isPresented: $isShowingLibrary, selection: $photoItem, matching: .images)
            .fullScreenCover(isPresented: $isShowingCamera) {
                CameraPicker(onPicked: onPicked)
                    .ignoresSafeArea()
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    // `Data` then `UIImage`, rather than asking for a
                    // `UIImage` directly: the transferable image loses the
                    // orientation metadata on some HEIC captures, and the
                    // avatar then arrives rotated a quarter turn.
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        onPicked(image)
                    }
                    photoItem = nil
                }
            }
    }
}

extension View {
    func avatarPicker(
        isPresentingOptions: Binding<Bool>,
        canRemove: Bool,
        onPicked: @escaping (UIImage) -> Void,
        onRemove: @escaping () -> Void
    ) -> some View {
        modifier(AvatarPickerModifier(
            isPresentingOptions: isPresentingOptions,
            canRemove: canRemove,
            onPicked: onPicked,
            onRemove: onRemove
        ))
    }
}

/// `UIImagePickerController`, because there is still no SwiftUI camera.
///
/// `.editedImage` first: the picker's own crop box is free, familiar, and
/// gives the user a say in what ends up inside the circle — `AvatarStore`'s
/// centre-square crop is the fallback for when they skip it.
private struct CameraPicker: UIViewControllerRepresentable {
    let onPicked: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.cameraDevice = .front
        controller.allowsEditing = true
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPicked: onPicked, dismiss: { dismiss() })
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onPicked: (UIImage) -> Void
        let dismiss: () -> Void

        init(onPicked: @escaping (UIImage) -> Void, dismiss: @escaping () -> Void) {
            self.onPicked = onPicked
            self.dismiss = dismiss
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.editedImage] as? UIImage ?? info[.originalImage] as? UIImage {
                onPicked(image)
            }
            dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }
    }
}
