import Foundation

/// Cross-process signal that a Wallet-automation capture just landed in the
/// local mirror. `CaptureIntent` is declared in the app target but, per its
/// own header comment, may still run in a separate host process from the
/// foregrounded app — a plain in-process `NotificationCenter` post would
/// never reach a `RootView` that's already running, which is exactly why a
/// capture made while Keepo is open changes nothing on screen until the
/// next foreground/reconnect/manual-retry event (C-09). A Darwin
/// notification is the one signal that crosses that process boundary.
enum CaptureNotify {
    // `nonisolated(unsafe)` — an immutable string literal, never mutated
    // after initialization, so cross-actor reads are safe.
    nonisolated(unsafe) static let name = "app.keepo.captureLanded" as CFString

    static func post() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name), nil, nil, true
        )
    }
}

/// Thin wrapper around the C-callback `CFNotificationCenter` API — Darwin
/// notifications carry no payload, so `onNotify` only ever signals "check
/// again," never what changed.
final class DarwinNotificationObserver {
    private let name: CFString
    private let onNotify: () -> Void

    init(name: CFString, onNotify: @escaping () -> Void) {
        self.name = name
        self.onNotify = onNotify
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<DarwinNotificationObserver>.fromOpaque(observer).takeUnretainedValue().onNotify()
            },
            name, nil, .deliverImmediately
        )
    }

    deinit {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(name), nil
        )
    }
}
