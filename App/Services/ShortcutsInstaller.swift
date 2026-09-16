import Foundation
import KeepoCore
import UIKit

/// Gets the Keepo Capture shortcut onto the phone in **one** tap, with
/// Apple's own two-tap path kept underneath it.
///
/// The supported way to share a shortcut is an `icloud.com/shortcuts/…`
/// link, which opens Safari, shows a preview page, and waits for a second
/// tap on "Get Shortcut". That page is a real cost at this point in
/// onboarding: it is the moment the user leaves Keepo, and it arrives
/// looking like a website rather than like the thing they just asked for.
///
/// `shortcuts://import-shortcut?url=…` skips it, but needs a URL to the
/// signed `.shortcut` file rather than to the share page. The
/// `capture-shortcut` Edge Function resolves that through the same record
/// API the icloud.com page calls — **which Apple does not document and may
/// change without notice.**
///
/// So this is written to fail into the supported path rather than to fail.
/// Every branch that cannot produce a direct import — no project
/// configured, the function unreachable, the record shaped differently,
/// Shortcuts not installed, the open refused — ends at the same
/// `icloud.com` link the button used before this existed. The user's worst
/// case is exactly the old behaviour, which is the property that makes
/// depending on an undocumented endpoint acceptable here at all.
@MainActor
enum ShortcutsInstaller {
    enum Outcome {
        /// Shortcuts opened with the import sheet — the one-tap path.
        case imported
        /// The icloud.com page opened. Two taps, and it still works.
        case openedSharePage
        /// Neither opened. The caller shows the written instructions.
        case failed
    }

    /// Long enough for a cold Edge Function, short enough that a tap never
    /// feels like it did nothing. Whatever has not answered by here is not
    /// worth making the user wait for when a working fallback is one line
    /// below.
    private static let resolveTimeout: TimeInterval = 4

    static func install(functionsBaseURL: URL?) async -> Outcome {
        if let direct = await importURL(functionsBaseURL: functionsBaseURL), await open(direct) {
            return .imported
        }
        guard let share = ShortcutsWalkthrough.installURL(functionsBaseURL: functionsBaseURL),
              await open(share) else {
            return .failed
        }
        return .openedSharePage
    }

    /// `shortcuts://import-shortcut?url=…`, or nil for any reason at all.
    private static func importURL(functionsBaseURL: URL?) async -> URL? {
        guard let functionsBaseURL,
              let endpoint = URL(
                  string: "functions/v1/\(ShortcutsWalkthrough.redirectFunctionName)?format=json",
                  relativeTo: functionsBaseURL
              ) else { return nil }

        var request = URLRequest(url: endpoint)
        request.timeoutInterval = resolveTimeout
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let resolved = try? JSONDecoder().decode(Resolved.self, from: data),
              let download = resolved.downloadURL,
              // Encoded against `.alphanumerics` rather than a URL character
              // set: the value is a signed CDN link whose signature can
              // contain `+`, `/` and `=`, every one of which means something
              // else inside a query string. Over-encoding a query value is
              // always safe; under-encoding it silently truncates the URL
              // Shortcuts is asked to fetch.
              let encoded = download.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        else { return nil }

        return URL(string: "shortcuts://import-shortcut?url=\(encoded)&name=Keepo%20Capture")
    }

    private static func open(_ url: URL) async -> Bool {
        guard UIApplication.shared.canOpenURL(url) else { return false }
        return await UIApplication.shared.open(url)
    }

    private struct Resolved: Decodable {
        /// Null whenever the Edge Function could not resolve the file, which
        /// it treats as an ordinary answer rather than an error.
        let downloadURL: String?
    }
}
