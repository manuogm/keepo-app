import Network
import Observation

/// The single source of truth for "is this device online" — backs the
/// persistent offline indicator (RootView) so every screen shares one
/// answer instead of each inferring it from its own last fetch error.
/// `NWPathMonitor`'s callback fires on a background queue; hop to main
/// before touching `@Observable` state.
///
/// **A singleton, and `init` is private.** "Is this device online" is a
/// process-wide fact, and each instance costs a live `NWPathMonitor` and a
/// dispatch queue subscribed to system path notifications for the app's
/// whole lifetime. There used to be two — this one, and a second built
/// inside `Outbox.startRetryLoop()` — computing the same boolean from the
/// same notifications. `Outbox` now reads this one.
@Observable
@MainActor
public final class NetworkMonitor {
    public static let shared = NetworkMonitor()

    public private(set) var isOffline = false

    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.isOffline = path.status != .satisfied
            }
        }
        monitor.start(queue: DispatchQueue(label: "app.keepo.network-monitor"))
    }

    deinit {
        monitor.cancel()
    }
}
