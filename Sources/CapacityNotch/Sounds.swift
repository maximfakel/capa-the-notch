import AppKit
import CapacityNotchCore

/// The few moments CapaTheNotch says with a sound (ADR 0007), each drawn once
/// from its recipe (`SoundRecipes`) and played as a buffer: the surface
/// pinned or let go, a file taken by the Shelf, a Clipping copied, Kapa
/// tapped or saying hello, dictated text kept, dictation failing, its model
/// ready, onboarding finished, a Provider that stopped answering, and a
/// Capacity Alert and the window's recovery after it. Nothing plays while the switch in Settings is off, while
/// macOS's own interface sounds are off, or while the Teleprompter runs —
/// someone reading a Script aloud is on a call or a recording.
@MainActor
final class Sounds {
    static let shared = Sounds()

    enum Cue: CaseIterable {
        case surfacePinned, shelfTook, clippingCopied, kapaTapped
        case dictationInserted, dictationCopied, dictationFailed, dictationModelReady
        case providerStopped, capacityAlert
        case capacityRecovered, kapaHello, onboardingFinished

        var patch: SoundPatch {
            switch self {
            case .surfacePinned, .shelfTook, .clippingCopied: SoundRecipes.tap
            case .kapaTapped, .dictationModelReady: SoundRecipes.success
            case .dictationInserted: SoundRecipes.success
            // Copied only is still the text the person said, kept for them.
            case .dictationCopied: SoundRecipes.success
            case .dictationFailed: SoundRecipes.error
            case .providerStopped, .capacityAlert: SoundRecipes.warning
            case .capacityRecovered, .kapaHello, .onboardingFinished: SoundRecipes.notification
            }
        }
    }

    /// Whether something on the surface wants quiet; the Teleprompter running.
    var isQuiet: () -> Bool = { false }

    private var sounds: [Cue: NSSound] = [:]

    /// Draws every sound ahead of the first that plays, away from the main
    /// thread: a few milliseconds each, but not in the middle of a drop.
    func prepare() {
        Task.detached(priority: .utility) {
            var drawn: [(Cue, Data)] = []
            for cue in Cue.allCases { drawn.append((cue, SoundFile.wav(SoundSynth.render(cue.patch)))) }
            await MainActor.run {
                for (cue, data) in drawn where self.sounds[cue] == nil { self.sounds[cue] = NSSound(data: data) }
            }
        }
    }

    func play(_ cue: Cue) {
        guard SoundPreference.isOn, Self.interfaceSoundsOn, !isQuiet() else { return }
        let sound = sounds[cue] ?? NSSound(data: SoundFile.wav(SoundSynth.render(cue.patch)))
        sounds[cue] = sound
        sound?.stop()
        sound?.play()
    }

    /// System Settings ▸ Sound ▸ "Play user interface sound effects".
    private static var interfaceSoundsOn: Bool {
        UserDefaults(suiteName: "com.apple.systemsound")?.object(forKey: "com.apple.sound.uiaudio.enabled") as? Bool
            ?? (UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["com.apple.sound.uiaudio.enabled"] as? Bool)
            ?? true
    }
}
