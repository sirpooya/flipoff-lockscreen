import AVFoundation
import os.log

private let logger = Logger(subsystem: "in.pooya.bilakh", category: "SoundPlayer")

/// Plays the user's chosen lock/unlock sound effect.
///
/// A single retained `AVAudioPlayer` per call, not a shared singleton instance —
/// overlapping locks/unlocks (rapid hotkey taps) should each get their own
/// playback rather than one cutting the other off.
enum SoundPlayer {
    /// Kept alive only long enough to finish playing; `AVAudioPlayer` has no
    /// strong owner otherwise and would be deallocated mid-playback. Keyed by
    /// ObjectIdentifier rather than making AVAudioPlayer itself Hashable — it's
    /// already NSObject-derived and NSObject.hash isn't overridable.
    private static var activePlayers: [ObjectIdentifier: AVAudioPlayer] = [:]

    static func play(_ sound: LockSound) {
        guard let name = sound.resourceName else { return }
        guard let url = Bundle.main.url(forResource: name, withExtension: "mp3", subdirectory: "Sounds")
            ?? Bundle.main.url(forResource: name, withExtension: "mp3") else {
            logger.error("Sound resource not found: \(name).mp3")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.volume = 0.7
            let key = ObjectIdentifier(player)
            activePlayers[key] = player
            player.prepareToPlay()
            player.play()
            // Cheaper than an AVAudioPlayerDelegate round-trip for a one-shot
            // effect: just drop the reference once playback should be done.
            DispatchQueue.main.asyncAfter(deadline: .now() + player.duration + 0.5) {
                activePlayers.removeValue(forKey: key)
            }
        } catch {
            logger.error("Failed to play \(name): \(error.localizedDescription)")
        }
    }
}

