import SwiftUI

@main
struct KeepoApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        MetricKitSubscriber.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
