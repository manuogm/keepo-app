import MetricKit
import OSLog

/// Free, built-in, no third-party SDK receiving data from a finance app
/// (spec). Apple delivers metric/diagnostic payloads to Xcode Organizer
/// automatically regardless of whether the app subscribes — this exists so
/// the app can also see them locally (`OSLog`, inspectable via Console.app
/// or `log show`), not because subscribing is what makes collection happen.
final class MetricKitSubscriber: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = MetricKitSubscriber()

    private let logger = Logger(subsystem: "app.keepo", category: "MetricKit")

    func start() {
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            logger.info("MXMetricPayload: \(payload.dictionaryRepresentation(), privacy: .public)")
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            logger.info("MXDiagnosticPayload: \(payload.dictionaryRepresentation(), privacy: .public)")
        }
    }
}
