import SwiftUI

@main
struct KeepoApp: App {
    init() {
        MetricKitSubscriber.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
