import AudioToolbox
import CapacityNotchCore
import Combine
import CoreAudio

/// The Mac's output volume, read from and written to the default output
/// device through Core Audio. No permission is asked for.
///
/// It follows the device: a change of output (headphones connected, a
/// display chosen) and a change of level from the keyboard or Control Center
/// both arrive as Core Audio notices, so the bar never lags. It listens only
/// while a bar is on screen: with the music page closed or the Music Module
/// off, Core Audio is not asked about anything (ADR 0003). A device whose
/// level cannot be set — some displays over HDMI, some USB converters — has no
/// speaker, and the page shows no bar.
@MainActor
final class SystemVolume: ObservableObject {
    static let shared = SystemVolume()

    /// Nil when the output device's level cannot be set.
    @Published private(set) var speaker: Speaker?

    private var device = AudioObjectID(kAudioObjectUnknown)
    /// How many bars are showing; the listeners run while any is.
    private var watchers = 0
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var deviceListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    /// Where the level was when it was muted, on a device with no mute of its
    /// own: muting there is setting the level to zero.
    private var levelBeforeMute: Double?

    private init() {}

    /// A bar appeared: follow the output device and its level.
    func startWatching() {
        watchers += 1
        guard watchers == 1 else { return }
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.follow() }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block) == noErr {
            outputListener = block
        }
        follow()
    }

    /// The last bar went: stop listening to Core Audio altogether.
    func stopWatching() {
        guard watchers > 0 else { return }
        watchers -= 1
        guard watchers == 0 else { return }
        if let outputListener {
            var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, outputListener)
        }
        outputListener = nil
        removeDeviceListeners()
        device = AudioObjectID(kAudioObjectUnknown)
    }

    /// Dragging the bar up from silence brings the sound back, as the
    /// system's own slider does.
    func set(level: Double) {
        if speaker?.isMuted == true, level > 0 {
            levelBeforeMute = nil
            set(muted: false)
        }
        write(level: level)
        read()
    }

    func toggleMute() {
        guard let speaker else { return }
        set(muted: !speaker.isMuted)
        read()
    }

    // MARK: - Core Audio

    private func write(level: Double) {
        guard device != kAudioObjectUnknown else { return }
        var value = Float32(min(max(level, 0), 1))
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    private func set(muted: Bool) {
        var address = Self.address(kAudioDevicePropertyMute)
        if Self.isSettable(device, &address) {
            var value = UInt32(muted ? 1 : 0)
            AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        } else if muted {
            levelBeforeMute = speaker?.level
            write(level: 0)
        } else if let level = levelBeforeMute {
            levelBeforeMute = nil
            write(level: level)
        }
    }

    /// The default output device, and listeners on its level and mute.
    private func follow() {
        removeDeviceListeners()
        levelBeforeMute = nil

        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        device = id

        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
            var address = Self.address(selector)
            guard AudioObjectHasProperty(device, &address) else { continue }
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.read() }
            }
            AudioObjectAddPropertyListenerBlock(device, &address, .main, block)
            deviceListeners.append((address, block))
        }
        read()
    }

    private func removeDeviceListeners() {
        for (address, block) in deviceListeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(device, &address, .main, block)
        }
        deviceListeners = []
    }

    private func read() {
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        guard device != kAudioObjectUnknown, Self.isSettable(device, &address) else {
            if speaker != nil { speaker = nil }
            return
        }
        var level = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &level)

        var muted = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        var muteAddress = Self.address(kAudioDevicePropertyMute)
        if AudioObjectHasProperty(device, &muteAddress) {
            AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &muted)
        }

        // A level raised from the keyboard ends a mute that was a zero.
        if level > 0 { levelBeforeMute = nil }
        let now = Speaker(level: Double(level), isMuted: muted != 0 || levelBeforeMute != nil)
        if speaker != now { speaker = now }
    }

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func isSettable(_ device: AudioObjectID, _ address: inout AudioObjectPropertyAddress) -> Bool {
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }
}
