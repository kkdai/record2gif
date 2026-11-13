import AVFoundation
import AVKit
import SwiftUI

struct LoopingVideoPreview: NSViewRepresentable {
    let videoURL: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.controlsStyle = .inline
        playerView.videoGravity = .resizeAspect
        context.coordinator.configure(url: videoURL, in: playerView)
        return playerView
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if context.coordinator.currentURL != videoURL {
            context.coordinator.configure(url: videoURL, in: nsView)
        }
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        coordinator.teardown(in: nsView)
    }

    @MainActor
    final class Coordinator {
        private(set) var currentURL: URL?
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?

        func configure(url: URL, in playerView: AVPlayerView) {
            teardown(in: playerView)
            currentURL = url

            let item = AVPlayerItem(url: url)
            let queuePlayer = AVQueuePlayer()
            queuePlayer.isMuted = true
            let playerLooper = AVPlayerLooper(player: queuePlayer, templateItem: item)

            self.player = queuePlayer
            self.looper = playerLooper
            playerView.player = queuePlayer
            queuePlayer.play()
        }

        func teardown(in playerView: AVPlayerView? = nil) {
            player?.pause()
            looper?.disableLooping()
            player?.removeAllItems()
            playerView?.player = nil
            looper = nil
            player = nil
            currentURL = nil
        }
    }
}
