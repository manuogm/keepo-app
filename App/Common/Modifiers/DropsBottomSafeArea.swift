import SwiftUI

/// Lets a screen's content run all the way to the physical bottom of the
/// display, past the home indicator.
///
/// The shell's tab bar floats *over* the screens rather than reserving a
/// row, so the home indicator's inset had nothing left to protect: all it
/// did was stop every screen 34pt short, which read as a grey band of page
/// background pinned across the bottom of the app. Content is meant to
/// carry on under the glass and off the edge — each scrolling view leaves
/// `KeepoTabBarMetrics.clearance` below its last row so nothing important
/// ends up trapped down there.
///
/// **It has to be the screen's own root view.** Neither the `TabView` nor
/// the `NavigationStack` above it will pass this down: both host their
/// content separately, so applied there it silently changes nothing but the
/// placement of the shell's own overlays — the strip stays exactly where it
/// was. Hence three call sites rather than one; the one place is this
/// modifier, so the three cannot drift apart.
extension View {
    func dropsBottomSafeArea() -> some View {
        ignoresSafeArea(.container, edges: .bottom)
    }
}
