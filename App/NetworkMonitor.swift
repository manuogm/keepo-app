import Network
import Observation

/// The single source of truth for "is this device online" — backs the
/// persistent offline indicator (RootView) so every screen shares one
/// answer instead of each inferring it from its own last fetch error.
/// `NWPathMonitor`'s callback fires on a background queue; hop to main
/// before touching `@Observable` state.
@Observable
@MainActor
public final class NetworkMonitor {
    public private(set) var isOffline = false

    private let monitor = NWPathMonitor()

    public init() {
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
