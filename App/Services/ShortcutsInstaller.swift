import Foundation
import KeepoCore
import UIKit

/// Gets the Keepo Capture shortcut onto the phone: the copy shipped inside
/// the app first, and the `icloud.com` share page behind it.
///
/// **There was a URL-scheme path here, and it cannot be rebuilt.**
/// `shortcuts://import-shortcut?url=…` skips the browser entirely, and this
/// type used to reach it by resolving the signed `.shortcut` asset through
/// the same record API the icloud.com page calls. It fails on iOS 26 with
/// "Import Failed. The shortcut URL provided was invalid", for a structural
/// reason rather than a bug in the URL being built.
///
/// Measured against Shortcuts 4610 on iOS 26.5, by opening the scheme with
/// hand-built URLs and watching `WFInterchangeManager` in the log:
///
/// | `url` parameter                        | result                        |
/// | -------------------------------------- | ----------------------------- |
/// | `www.icloud.com/shortcuts/<id>` ± query | accepted, downloads          |
/// | `www.icloud.com/<anything>`             | accepted, downloads          |
/// | `cvws.icloud-content.com/…/x.shortcut`  | **rejected before any fetch** |
/// | `example.com/a.shortcut`                | **rejected before any fetch** |
/// | a self-hosted `.shortcut` over HTTP     | **rejected before any fetch** |
///
/// The parameter is checked against an `icloud.com` host allowlist and
/// rejected *at parse time* — the self-hosted server logged zero requests —
/// which is why no amount of re-encoding, and no change of where the file
/// lives, moved the outcome. Every asset on the record is served from
/// `icloud-content.com`, a different registrable domain, so no URL can
/// satisfy both the allowlist and the file.
///
/// **So the file is handed over as a file.** `Keepo Capture.shortcut` ships
/// in the bundle and goes to Shortcuts through `UIDocumentInteractionController`,
/// which needs no network, no iCloud link, and no browser. The share page
/// stays behind it for the case where nothing on the device can open the
/// document — and because it is the one route that keeps working if the
/// bundled copy is ever the wrong version, since the redirect behind it can
/// be re-pointed with a `supabase secrets set` rather than a release.
///
/// Neither route can be a single tap: the "Add Shortcut" confirmation is
/// Apple's, shown for every third-party import, and there is no way to
/// suppress it for an untrusted shortcut.
@MainActor
enum ShortcutsInstaller {
    enum Outcome {
        /// The bundled file was offered to Shortcuts. No network involved.
        case offeredBundledFile
        /// The icloud.com page opened instead.
        case openedSharePage
        /// Neither. The caller shows the written instructions.
        case failed
    }

    static func install(functionsBaseURL: URL?) async -> Outcome {
        if BundledShortcut.presentOpenInMenu() { return .offeredBundledFile }
        guard let share = ShortcutsWalkthrough.installURL(functionsBaseURL: functionsBaseURL),
              await open(share) else {
            return .failed
        }
        return .openedSharePage
    }

    private static func open(_ url: URL) async -> Bool {
        guard UIApplication.shared.canOpenURL(url) else { return false }
        return await UIApplication.shared.open(url)
    }
}

/// The copy of the shortcut that ships with the app, offered to whichever
/// installed app can open a `.shortcut` — in practice, Shortcuts alone.
///
/// **A class, and a singleton, because `UIDocumentInteractionController`
/// requires it.** The controller is not retained by the presentation: let
/// it go out of scope at the end of the method that made it and the menu
/// vanishes mid-animation. It is held here until the next one replaces it.
///
/// The file is copied to `tmp` before being offered. The bundle is
/// read-only and the receiving app is handed a URL it may want to open in
/// place, and the copy is also what guarantees the name Shortcuts shows is
/// `ShortcutsWalkthrough.shortcutName` rather than whatever the resource
/// happens to be called.
@MainActor
private final class BundledShortcut: NSObject, UIDocumentInteractionControllerDelegate {
    private static let shared = BundledShortcut()
    private var controller: UIDocumentInteractionController?

    /// `false` whenever the menu could not be shown — no bundled copy, no
    /// window to present from, or nothing installed that opens the type —
    /// which is exactly when the caller should fall back to the share page.
    static func presentOpenInMenu() -> Bool { shared.present() }

    private func present() -> Bool {
        guard let file = Self.stagedCopy, let host = Self.topViewController else { return false }
        let controller = UIDocumentInteractionController(url: file)
        controller.delegate = self
        self.controller = controller
        return controller.presentOpenInMenu(from: host.view.bounds, in: host.view, animated: true)
    }

    /// The bundled resource, copied into `tmp` under the shortcut's own
    /// name. `nil` if the app was built without it, which is a build
    /// mistake rather than a runtime condition — hence the fallback rather
    /// than an error.
    private static var stagedCopy: URL? {
        guard let source = Bundle.main.url(
            forResource: ShortcutsWalkthrough.shortcutName, withExtension: "shortcut"
        ) else { return nil }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(ShortcutsWalkthrough.shortcutName).shortcut")
        try? FileManager.default.removeItem(at: destination)
        guard (try? FileManager.default.copyItem(at: source, to: destination)) != nil else {
            return nil
        }
        return destination
    }

    /// **The topmost presented controller, not the root.** The install
    /// button is inside a sheet everywhere it appears — onboarding's
    /// checklist and the setup flow in My Automations are both modals — and
    /// presenting from the root while a sheet is up throws.
    private static var topViewController: UIViewController? {
        guard var controller = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })?
            .keyWindow?.rootViewController
        else { return nil }
        while let presented = controller.presentedViewController { controller = presented }
        return controller
    }
}
