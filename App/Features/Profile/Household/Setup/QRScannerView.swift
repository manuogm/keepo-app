import AVFoundation
import SwiftUI
import UIKit

// The camera half of `HouseholdQRView`, split out for the project's
// file-length lint — and because "point a camera at a QR code" knows nothing
// about households.

/// The camera, looking for one QR code.
///
/// `AVCaptureMetadataOutput` rather than the Vision framework: the job is
/// "tell me when a QR code is in frame", which this does in a dozen lines with
/// hardware detection and no per-frame image processing.
struct QRScannerView: UIViewControllerRepresentable {
    let onFound: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onFound = onFound
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {
        controller.onFound = onFound
    }

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onFound: ((String) -> Void)?

        private let captureSession = AVCaptureSession()
        private var previewLayer: AVCaptureVideoPreviewLayer?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            configure()
        }

        private func configure() {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  captureSession.canAddInput(input) else { return }
            captureSession.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard captureSession.canAddOutput(output) else { return }
            captureSession.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            // Set *after* the output is attached to the session — the
            // available types are empty until then, and assigning `.qr`
            // beforehand throws.
            output.metadataObjectTypes = [.qr]

            let preview = AVCaptureVideoPreviewLayer(session: captureSession)
            preview.videoGravity = .resizeAspectFill
            view.layer.addSublayer(preview)
            previewLayer = preview
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            previewLayer?.frame = view.bounds
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            guard !captureSession.isRunning else { return }
            // Off the main thread: `startRunning` blocks until the camera is
            // configured, and on the main queue that is a visible hitch as
            // the sheet presents.
            let session = UncheckedSendable(captureSession)
            Task.detached { session.value.startRunning() }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            guard captureSession.isRunning else { return }
            let session = UncheckedSendable(captureSession)
            Task.detached { session.value.stopRunning() }
        }

        /// `nonisolated` with an explicit hop, rather than letting the
        /// conformance be inferred as main-actor: `AVCaptureMetadataOutput`
        /// declares this delegate without actor isolation, and a
        /// main-actor-isolated implementation of it is a data race the
        /// compiler refuses outright. The callback queue is already `.main`
        /// (set in `configure`), so the hop is free.
        nonisolated func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let payload = object.stringValue else { return }
            Task { @MainActor [weak self] in
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                self?.onFound?(payload)
            }
        }
    }
}
