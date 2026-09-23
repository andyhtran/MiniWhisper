import AppKit

/// Brief, distinct audio cues for "recording started" and "recording
/// stopped" (requested in andyhtran/MiniWhisper#26 — without looking at the
/// menu bar there's currently no way to tell MiniWhisper is listening).
///
/// Uses two of macOS's own built-in system sounds (`/System/Library/Sounds`)
/// rather than a bundled audio file: they're short, unobtrusive, already
/// professionally produced, carry no licensing question, and sound native
/// because most users have already heard them elsewhere in the OS. Same
/// approach and same two sounds as Ghost Pepper (another local dictation
/// app), which solved this exact request already.
final class SoundEffects {
    private let startSound: NSSound?
    private let stopSound: NSSound?
    private let isEnabled: () -> Bool
    private let startPlayer: () -> Void
    private let stopPlayer: () -> Void

    init(
        isEnabled: @escaping () -> Bool = { SoundEffectsSettings.enabled },
        startPlayer: (() -> Void)? = nil,
        stopPlayer: (() -> Void)? = nil
    ) {
        startSound = NSSound(named: "Tink")
        stopSound = NSSound(named: "Pop")
        self.isEnabled = isEnabled
        // `stop()` before `play()`: a recording started and stopped again
        // quickly enough (an accidental toggle double-tap, still audible
        // during the ~sub-second sound) would otherwise let two overlapping
        // playbacks of the same sound run at once.
        self.startPlayer = startPlayer ?? { [weak startSound] in
            startSound?.stop()
            startSound?.play()
        }
        self.stopPlayer = stopPlayer ?? { [weak stopSound] in
            stopSound?.stop()
            stopSound?.play()
        }
    }

    func playStart() {
        guard isEnabled() else { return }
        startPlayer()
    }

    func playStop() {
        guard isEnabled() else { return }
        stopPlayer()
    }
}
