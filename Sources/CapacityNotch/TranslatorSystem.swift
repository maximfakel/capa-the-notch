@preconcurrency import ApplicationServices
import AppKit
import Carbon
import CapacityNotchCore
import CoreGraphics

/// The general clipboard, as `TranslatorShortcutRun` borrows it.
@MainActor
final class SystemTranslatorPasteboard: TranslatorPasteboard {
    private let board = NSPasteboard.general
    var changeCount: Int { board.changeCount }

    func snapshot() -> PasteboardSnapshot {
        PasteboardSnapshot(items: (board.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type.rawValue, $0) } })
        })
    }

    func restore(_ snapshot: PasteboardSnapshot) {
        board.clearContents()
        guard !snapshot.items.isEmpty else { return }
        board.writeObjects(snapshot.items.map { types in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
            return item
        })
    }

    func string() -> String? { board.string(forType: .string) }
    func writeOwnText(_ text: String) { OwnClipboard.copy(text) }
    func setBorrowed(_ borrowed: Bool) { OwnClipboard.setBorrowed(borrowed) }
}

/// The application in front when the shortcut was pressed: its focused
/// field, read through Accessibility or ⌘C, and — when the person asks —
/// written with Dictation's verified insertion (and its ⌘V fallback).
@MainActor
final class FrontmostTranslatorTarget: TranslatorTarget {
    private let focused: AXUIElement?
    private let delivery: DictationDelivery?

    /// Taken at the moment the shortcut is pressed, before anything changes.
    init() {
        focused = AXIsProcessTrusted() ? Self.focusedElement() : nil
        delivery = DictationDelivery.capture()
    }

    var isSecureField: Bool { focused.map(Self.isSecure) ?? false }

    /// A text field or area whose selected text Accessibility lets be set,
    /// or one Dictation's delivery can write into in place.
    var isEditable: Bool {
        if let focused, Self.isTextField(focused), Self.isSelectedTextSettable(focused) { return true }
        return delivery?.canReplaceThroughAccessibility ?? false
    }

    var applicationName: String? {
        let pid = delivery?.processIdentifier ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        return pid.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName }
    }

    /// Brings the captured application back in front and waits, half a
    /// second at most, until it is; then a moment for its window to take
    /// the keyboard back from the surface.
    func activate() async {
        guard let pid = delivery?.processIdentifier, let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.activate()
        for _ in 0..<25 where NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            try? await Task.sleep(for: .milliseconds(20))
        }
        try? await Task.sleep(for: .milliseconds(150))
    }

    func selectedTextThroughAccessibility() -> String? {
        guard let focused else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    func sendCopy() { Self.post(keyCode: 8) }

    func replaceSelection(with text: String) async -> Bool {
        guard let delivery else { return false }
        return await delivery.insert(text) == nil
    }

    /// ⌘ and a key, to the session, as Dictation sends ⌘V.
    private static func post(keyCode: CGKeyCode) {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// The shortcut's own ⌃⌥ would ride on a ⌘C sent while they are still
    /// held; wait, a second at most, for the hand to come off them.
    static func waitForModifiersReleased() async {
        for _ in 0..<50 {
            let held = NSEvent.modifierFlags.intersection([.control, .option, .command, .shift])
            if held.isEmpty { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var app: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &app) == .success,
              let app, CFGetTypeID(app) == AXUIElementGetTypeID() else { return nil }
        var element: CFTypeRef?
        guard AXUIElementCopyAttributeValue(unsafeDowncast(app, to: AXUIElement.self), kAXFocusedUIElementAttribute as CFString, &element) == .success,
              let element, CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(element, to: AXUIElement.self)
    }

    private static func isTextField(_ element: AXUIElement) -> Bool {
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
              let role = role as? String else { return false }
        return [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXTextEntryArea"].contains(role)
    }

    private static func isSelectedTextSettable(_ element: AXUIElement) -> Bool {
        var writable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &writable) == .success
            && writable.boolValue
    }

    private static func isSecure(_ element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<8 {
            guard let node = current else { break }
            var subrole: CFTypeRef?
            if AXUIElementCopyAttributeValue(node, kAXSubroleAttribute as CFString, &subrole) == .success,
               subrole as? String == kAXSecureTextFieldSubrole { return true }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            current = unsafeDowncast(parent, to: AXUIElement.self)
        }
        return false
    }
}

/// The translator's global shortcut, through Carbon as Dictation's is, so it
/// needs no Accessibility grant to be heard. Its own signature keeps the two
/// apart.
@MainActor
final class TranslatorHotKey {
    private var handler: EventHandlerRef?
    private var shortcut: EventHotKeyRef?
    var pressed: () -> Void = {}
    private static let signature: OSType = 0x434E_5452 // "CNTR"

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == 0x434E_5452 else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated {
                Unmanaged<TranslatorHotKey>.fromOpaque(context).takeUnretainedValue().pressed()
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    /// nil unregisters. False when macOS refused it: another application has it.
    func register(_ key: KeyShortcut?) -> Bool {
        if let shortcut { UnregisterEventHotKey(shortcut) }
        shortcut = nil
        guard let key else { return true }
        var flags: UInt32 = 0
        if key.modifiers.contains(.control) { flags |= UInt32(controlKey) }
        if key.modifiers.contains(.option) { flags |= UInt32(optionKey) }
        if key.modifiers.contains(.command) { flags |= UInt32(cmdKey) }
        if key.modifiers.contains(.shift) { flags |= UInt32(shiftKey) }
        return RegisterEventHotKey(key.keyCode, flags, EventHotKeyID(signature: Self.signature, id: 1), GetEventDispatcherTarget(), 0, &shortcut) == noErr
    }
    // Owned by the controller for the application's lifetime.
}
