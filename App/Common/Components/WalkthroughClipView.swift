import AVKit
import KeepoCore
import SwiftUI

/// One silent looping clip of a Shortcuts step, or nothing at all.
///
/// **Nothing at all is a supported state, not a failure state.** The clips
/// are recorded on a real device (Shortcuts' automation UI does not exist
/// on the Simulator) and may not be in the bundle yet; every
/// `WalkthroughStep`'s `clip` is optional, and a name there is not a
/// promise the file exists. This checks, and draws nothing when it is
/// missing — so the walkthrough degrades to its written steps, which is the
/// durable half anyway.
///
/// **Muted is not enough — the clips ship with no audio track at all**, so
/// there is nothing here to duck whatever the user is listening to. The
/// player is still explicitly muted as a second line of defence, because a
/// clip re-recorded carelessly one day would otherwise start playing sound
/// into someone's headphones during onboarding.
///
/// `AVPlayerLooper` rather than watching for `AVPlayerItemDidPlayToEndTime`
/// and seeking to zero: the notification path stutters visibly at the seam,
/// which on a three-second instructional loop is the only thing anyone
/// would look at.
struct WalkthroughClipView: View {
    let clip: String?

    @State private var player: AVQueuePlayer?
    /// Held only to keep it alive — an `AVPlayerLooper` that goes out of
    /// scope stops looping, and the clip plays exactly once.
    @State private var looper: AVPlayerLooper?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .aspectRatio(Self.aspectRatio, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.card))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .task(id: clip) { start() }
        .onDisappear {
            player?.pause()
            player = nil
            looper = nil
        }
    }

    /// Portrait phone capture. Fixed rather than read from the asset so the
    /// row does not reflow the instant a clip finishes loading.
    private static let aspectRatio: CGFloat = 9.0 / 16.0

    /// Honours Reduce Motion by not playing at all. A looping video is
    /// exactly the kind of unsolicited repeated movement that setting
    /// exists for, and the written step beside it says the same thing —
    /// which is the whole reason the text is the durable half.
    private func start() {
        guard !reduceMotion, let clip, let url = Self.url(for: clip) else {
            player = nil
            looper = nil
            return
        }
        let queue = AVQueuePlayer()
        queue.isMuted = true
        // Never take the audio session: the clips are silent, so there is
        // nothing to play and nothing to interrupt.
        queue.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: url))
        player = queue
        queue.play()
    }

    private static func url(for clip: String) -> URL? {
        Bundle.main.url(forResource: clip, withExtension: "mp4")
    }
}
