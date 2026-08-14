import SwiftUI
import AVFoundation

/// A one-shot video layer for `LockVisual.video`.
///
/// `AVPlayerLayer` directly rather than AVKit's `VideoPlayer`/`AVPlayerView`:
/// both of those ship playback controls and a click target, which on a shield
/// window would hand a snoop a scrub bar. This is a bare layer with no
/// interaction surface at all.
///
/// The clip plays through once and holds its last frame (`actionAtItemEnd =
/// .none`) — a scare is a single event, and a jump scare on repeat stops being
/// one after the second pass. Each reveal replays it from frame one, so the gag
/// still fires fresh every time someone touches the machine.
struct LockVideoView: NSViewRepresentable {
    let url: URL
    /// Drives playback: true starts the clip from the beginning, false holds it on
    /// frame one (paused, not blank — see `Coordinator.setPlaying`).
    var playing: Bool = true
    var muted: Bool = false
    /// `.resizeAspect` — the clip is scaled to the display's full height with
    /// nothing cropped. `.resizeAspectFill` would fill the width instead and eat
    /// the top and bottom of the frame, which on a face-filling clip cuts off the
    /// part that matters.
    var gravity: AVLayerVideoGravity = .resizeAspect

    func makeNSView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        context.coordinator.attach(to: view, url: url, gravity: gravity)
        context.coordinator.setMuted(muted)
        context.coordinator.setPlaying(playing)
        return view
    }

    func updateNSView(_ nsView: PlayerContainerView, context: Context) {
        context.coordinator.attach(to: nsView, url: url, gravity: gravity)
        context.coordinator.setMuted(muted)
        context.coordinator.setPlaying(playing)
    }

    static func dismantleNSView(_ nsView: PlayerContainerView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Hosts the player layer and keeps it filling the view. A plain
    /// `NSHostingView`-style auto-resize isn't enough: `AVPlayerLayer` is a raw
    /// CALayer and doesn't participate in Auto Layout, so the frame is set in
    /// `layout()`.
    final class PlayerContainerView: NSView {
        var playerLayer: AVPlayerLayer?

        override func layout() {
            super.layout()
            CATransaction.begin()
            // Without this the layer animates to each new size, which on a
            // display hot-plug reads as the video sliding into place.
            CATransaction.setDisableActions(true)
            playerLayer?.frame = bounds
            CATransaction.commit()
        }

        // The shield swallows input on its own; the video must never be a
        // click target that could steal a hit from the window beneath it.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    final class Coordinator {
        private var player: AVPlayer?
        private var currentURL: URL?
        private var isPlaying = false
        /// Whether this player has been asked for frame one yet. See `setPlaying`.
        private var primedFirstFrame = false

        func attach(to view: PlayerContainerView, url: URL, gravity: AVLayerVideoGravity) {
            if currentURL != url {
                teardown()
                let player = AVPlayer(url: url)
                // A lock screen clip is a one-off effect, not media playback:
                // never let it duck or pause other audio, and don't let the
                // system pause it when it thinks nothing is watching.
                player.actionAtItemEnd = .none
                player.automaticallyWaitsToMinimizeStalling = false
                self.player = player
                self.currentURL = url
                self.primedFirstFrame = false
            }

            guard let player else { return }

            if view.playerLayer?.player !== player {
                view.playerLayer?.removeFromSuperlayer()
                let layer = AVPlayerLayer(player: player)
                layer.frame = view.bounds
                view.layer?.addSublayer(layer)
                view.playerLayer = layer
            }
            view.playerLayer?.videoGravity = gravity
        }

        func setMuted(_ muted: Bool) {
            player?.isMuted = muted
        }

        func setPlaying(_ playing: Bool) {
            guard let player else { return }

            if playing {
                guard !isPlaying else { return }
                isPlaying = true
                // Rewind on every start, not just the first — each reveal is a
                // fresh scare.
                player.seek(to: .zero)
                player.play()
                return
            }

            if isPlaying {
                isPlaying = false
                player.pause()
            }

            // A player that has never played renders nothing: the layer stays
            // black until it's asked for a specific time. One precise seek to
            // zero is what makes a paused view show frame one instead of a black
            // rectangle — the Settings preview's whole job. Done once per player,
            // since every `updateNSView` lands here while paused.
            if !primedFirstFrame {
                primedFirstFrame = true
                player.pause()
                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }

        func teardown() {
            player?.pause()
            player = nil
            currentURL = nil
            isPlaying = false
            primedFirstFrame = false
        }
    }
}
