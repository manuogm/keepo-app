import SwiftUI

/// The system share sheet, reporting whether the file actually went
/// somewhere — so the screen can clean up after it and confirm success.
///
/// Its own file rather than the bottom of ExportView.swift, which is at the
/// project's file-length limit. Nothing about a UIKit bridge belongs to the
/// Export screen specifically; it was simply written there first.
struct ShareSheet: UIViewControllerRepresentable {
    let fileURL: URL
    let onComplete: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in onComplete(completed) }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
