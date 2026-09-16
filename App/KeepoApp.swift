import SwiftUI

@main
struct KeepoApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        MetricKitSubscriber.shared.start()
        // Must run before any tip is displayed, so it belongs at launch
        // rather than on the first screen that shows one.
        KeepoTipsConfiguration.configure()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
