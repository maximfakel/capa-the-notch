import Carbon
import CapacityNotchCore

/// Carbon observes hold/release without an Accessibility grant. Escape is
/// registered only for an active session, never while the module is idle.
@MainActor
final class DictationHotKey {
    private var handler: EventHandlerRef?
    private var shortcut: EventHotKeyRef?
    private var escape: EventHotKeyRef?
    var pressed: () -> Void = {}
    var released: () -> Void = {}
    var cancelled: () -> Void = {}
    private static let signature: OSType = 0x434E4443
    init() {
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)), EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == 0x434E4443 else { return OSStatus(eventNotHandledErr) }
            let key = id.id
            let down = GetEventKind(event) == kEventHotKeyPressed
            MainActor.assumeIsolated {
                let owner = Unmanaged<DictationHotKey>.fromOpaque(context).takeUnretainedValue()
                if key == 2 { if down { owner.cancelled() } }
                else if down { owner.pressed() } else { owner.released() }
            }
            return noErr
        }, 2, &specs, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func register(_ key: KeyShortcut?) -> Bool {
        if let shortcut { UnregisterEventHotKey(shortcut) }; shortcut = nil
        guard let key else { return true }
        var flags: UInt32 = 0
        if key.modifiers.contains(.control) { flags |= UInt32(controlKey) }
        if key.modifiers.contains(.option) { flags |= UInt32(optionKey) }
        if key.modifiers.contains(.command) { flags |= UInt32(cmdKey) }
        if key.modifiers.contains(.shift) { flags |= UInt32(shiftKey) }
        return RegisterEventHotKey(key.keyCode, flags, EventHotKeyID(signature: Self.signature, id: 1), GetEventDispatcherTarget(), 0, &shortcut) == noErr
    }
    func captureEscape(_ active: Bool) {
        if let escape { UnregisterEventHotKey(escape) }; escape = nil
        if active { RegisterEventHotKey(53, 0, EventHotKeyID(signature: Self.signature, id: 2), GetEventDispatcherTarget(), 0, &escape) }
    }
    // Owned by the application controller for its entire lifetime.
}
