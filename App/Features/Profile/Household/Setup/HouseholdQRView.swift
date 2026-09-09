import AVFoundation
import CoreImage.CIFilterBuiltins
import KeepoCore
import SwiftUI

/// The road that works when the two phones cannot find each other.
///
/// ## Why this deliberately skips the ceremony
///
/// The ten-step animation is *about* two phones talking to each other: the
/// travelling particles, the mirrored steps, the two houses filling in
/// lockstep. Reaching this screen means exactly that link could not be
/// established. Playing the choreography anyway, over a channel that is one
/// scan and then nothing, would be the app performing a connection it does
/// not have — the two phones would drift apart within a second and the moment
/// would read as broken rather than as ceremonial.
///
/// So the fallback is plain and quick, and it produces the identical
/// household: the same `create_invite` token, the same `accept_invite`, the
/// same automatic category merge, and the same five-screen report for the
/// owner afterwards. Nothing about the *result* is second class — only the
/// theatre is missing, and it is missing because it would have been a lie.
struct HouseholdQRView: View {
    let session: SessionStore
    let role: HouseholdPairingIdentity.Role
    let accountIds: [UUID]
    let categoryIds: [UUID]
    var onJoined: () -> Void

    /// The scheme in front of the token, so a Keepo camera pointed at a
    /// Wi-Fi QR code says "that isn't a Keepo code" instead of posting a
    /// random string to `accept_invite` and surfacing whatever the server
    /// says about it.
    static let payloadPrefix = "keepo-household:"

    @Environment(\.dismiss) private var dismiss

    @State private var token: String?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var hasJoined = false
    @State private var isShowingReport = false

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.Palette.bgCanvas.ignoresSafeArea()
                content
            }
            .navigationTitle(role == .owner ? "Your Household Code" : "Scan Their Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
            }
            .task { await prepare() }
            .fullScreenCover(isPresented: $isShowingReport) {
                // No avatars: the peer link is what carries a face before the
                // household is final, and this is the road taken because there
                // is no peer link. The container falls back to initials, the
                // same as for a member with no photo.
                HouseholdReportFlow(session: session) {
                    await session.syncNow()
                    session.refresh.bump()
                    isShowingReport = false
                    onJoined()
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch role {
        case .owner: ownerContent
        case .guest: guestContent
        }
    }

    // MARK: - Owner: show the code

    private var ownerContent: some View {
        VStack(spacing: AppTheme.Spacing.xl) {
            Spacer()

            if let token {
                QRCodeImage(payload: Self.payloadPrefix + token)
                    .frame(width: 220, height: 220)
                    .padding(AppTheme.Spacing.l)
                    .background(
                        // Always a light plate, in both appearances. A QR code
                        // is read by contrast, and a dark-mode card behind a
                        // dark-mode code is a code no camera can resolve.
                        Color.white,
                        in: RoundedRectangle(cornerRadius: AppTheme.Radius.surface)
                    )
                    .elevation(.resting)
            } else if isWorking {
                ProgressView()
            }

            VStack(spacing: AppTheme.Spacing.s) {
                Text("Have them scan this")
                    .font(AppTheme.Typography.sectionTitle)
                    .foregroundStyle(AppTheme.Palette.textPrimary)
                Text(
                    "It works once and expires in seven days. Nothing is shared until they scan it — "
                        + "you'll review everything before the household is final."
                )
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let errorMessage {
                FormErrorText(message: errorMessage)
            }

            Spacer()

            HStack(spacing: AppTheme.Spacing.s) {
                ProgressView()
                Text("Waiting for them to scan")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.xxl)
        .padding(.bottom, AppTheme.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Guest: read the code

    private var guestContent: some View {
        VStack(spacing: 0) {
            QRScannerView { payload in
                guard !hasJoined, payload.hasPrefix(Self.payloadPrefix) else { return }
                hasJoined = true
                Task { await join(String(payload.dropFirst(Self.payloadPrefix.count))) }
            }
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.surface))
            .padding(AppTheme.Spacing.l)
            .overlay {
                if isWorking {
                    ProgressView()
                        .padding(AppTheme.Spacing.l)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AppTheme.Radius.card))
                }
            }

            VStack(spacing: AppTheme.Spacing.s) {
                Text("Point at their code")
                    .font(AppTheme.Typography.sectionTitle)
                    .foregroundStyle(AppTheme.Palette.textPrimary)
                Text("They'll find it under \"Show QR Code\" on their own Household Setup screen.")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if let errorMessage {
                    FormErrorText(message: errorMessage)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.xxl)
            .padding(.bottom, AppTheme.Spacing.xxl)
        }
    }

    // MARK: - Work

    private func prepare() async {
        guard role == .owner, token == nil else { return }
        isWorking = true
        errorMessage = nil
        do {
            try await ensureHousehold()
            token = try await HouseholdRepository.createInvite(
                client: session.client, accountIds: accountIds, categoryIds: categoryIds
            )
            await waitForMember()
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
        isWorking = false
    }

    private func ensureHousehold() async throws {
        guard let userId = session.profile?.id.uuidString else { return }
        let existing = try? await session.dbQueue.read { database in
            try LocalTableQueries.myHousehold(database, userId: userId)
        }
        guard existing == nil else { return }
        try await HouseholdRepository.create(client: session.client)
        await session.syncNow()
    }

    /// Polling, because there is no peer link here to be told over and this
    /// build has no realtime transport (Phase 19 left `household_events` on
    /// polling for the same reason). Five seconds is slow enough not to
    /// hammer the API while somebody lines up a camera, and fast enough that
    /// the wait never feels stuck.
    ///
    /// When they land, this runs **the same automatic category merge the
    /// ceremony runs** and then opens **the same report**. Skipping either
    /// would make a QR-built household genuinely worse than a paired one
    /// rather than merely less theatrical: every near-miss category would stay
    /// unmatched, with no screen ever offering to fix it.
    private func waitForMember() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            await session.syncNow()
            guard (try? await HouseholdRepository.memberProfile(client: session.client)) != nil else {
                continue
            }
            try? await HouseholdAutoMerge.run(session: session, selectedCategoryIds: categoryIds)
            await session.syncNow()
            session.refresh.bump()
            isShowingReport = true
            return
        }
    }

    private func join(_ token: String) async {
        isWorking = true
        errorMessage = nil
        do {
            try await HouseholdRepository.acceptInvite(
                client: session.client, token: token,
                accountIds: accountIds, categoryIds: categoryIds
            )
            await session.syncNow()
            session.refresh.bump()
            onJoined()
        } catch {
            errorMessage = UserFacingError.describe(error)
            // Let them try again — a failed scan is usually a stale or
            // already-used code, and locking the camera after one attempt
            // would mean closing and reopening the sheet to retry.
            hasJoined = false
        }
        isWorking = false
    }
}

// MARK: - Rendering

/// A QR code as an `Image`.
///
/// `.interpolation(.none)` is load-bearing: the generator emits a bitmap
/// roughly 25 modules across, and the default smoothing blurs a scaled-up
/// code into something a camera cannot resolve at all.
private struct QRCodeImage: View {
    let payload: String

    var body: some View {
        if let image = render() {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .accessibilityLabel("Household QR code")
        } else {
            Image(systemName: "qrcode")
                .resizable()
                .scaledToFit()
                .foregroundStyle(AppTheme.Palette.textSecondary)
        }
    }

    private func render() -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        // "M" — 15% of the code can be obscured and still read. The default
        // "L" is fine on a screen, but this one gets photographed at an angle
        // across a kitchen table.
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let context = CIContext()
        guard let cgImage = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - Scanning

/// The camera, looking for one QR code.
///
/// `AVCaptureMetadataOutput` rather than the Vision framework: the job is
/// "tell me when a QR code is in frame", which this does in a dozen lines with
/// hardware detection and no per-frame image processing.
private struct QRScannerView: UIViewControllerRepresentable {
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
