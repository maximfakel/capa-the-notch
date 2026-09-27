import AppKit
import ApplicationServices
import CoreGraphics
import os

/// Captures the foreground application before recording. It prefers a verified
/// AX edit, then posts Cmd-V to the captured app for embedded editors.
@MainActor
struct DictationDelivery {
    private let pid: pid_t
    private let element: AXUIElement?
    private let selection: CFRange?
    private let original: String?
    private static let logger = Logger(subsystem: "app.capacitynotch.CapacityNotch", category: "DictationDelivery")
    private(set) static var lastCaptureFailure: String?

    static func capture() -> Self? {
        // Accessibility is optional: System Events can still deliver Cmd-V and
        // will request Automation access on first use. Without AX trust, keep
        // the frontmost PID and skip only the richer focus inspection.
        let accessibilityTrusted = AXIsProcessTrusted()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let focusedPID = accessibilityTrusted ? focusedApplicationPID() : nil
        let workspacePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let windowPID = frontmostExternalWindowPID(excluding: ownPID)
        guard let targetPID = [focusedPID, workspacePID, windowPID].compactMap({ $0 }).first(where: { $0 != ownPID }) else {
            lastCaptureFailure = "No external app found. AX focus: \(focusedPID.map(String.init) ?? "none"); workspace: \(workspacePID.map(String.init) ?? "none"); front window: \(windowPID.map(String.init) ?? "none")."
            logger.error("Capture skipped: \(lastCaptureFailure ?? "no target")")
            return nil
        }
        lastCaptureFailure = nil
        if !accessibilityTrusted {
            logger.info("Accessibility unavailable; keeping the target for System Events fallback")
        }
        // Some editors expose their focused item with a non-text AX role. Keep
        // that exact focus token for System Events fallback instead of dropping
        // the whole delivery target. Password fields remain excluded.
        let focusedElement = accessibilityTrusted ? focused(targetPID) : nil
        if let focusedElement, isSecure(focusedElement) {
            logger.info("Capture skipped: secure text field")
            return nil
        }
        let editable = focusedElement.map(isEditableTarget) ?? false
        if !editable {
            let role = focusedElement.flatMap { value($0, kAXRoleAttribute) as? String } ?? "unknown"
            logger.info("Using System Events fallback for AX role \(role, privacy: .public)")
        }
        return Self(
            pid: targetPID,
            element: focusedElement,
            selection: editable ? focusedElement.flatMap(range) : nil,
            original: editable ? focusedElement.flatMap { value($0, kAXValueAttribute) as? String } : nil
        )
    }

    func insert(_ text: String) async -> String? {
        guard isTargetAppFrontmost() else {
            Self.logger.info("Insertion skipped: captured app is no longer frontmost")
            return "The target application stopped being active before insertion."
        }

        if isCapturedFocusCurrent(), let element, let original, let selection,
           let currentSelection = Self.range(element),
           let current = Self.value(element, kAXValueAttribute) as? String,
           current == original,
           currentSelection.location == selection.location,
           currentSelection.length == selection.length,
           selection.location >= 0, selection.length >= 0,
           selection.location + selection.length <= (original as NSString).length {
            var writable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &writable) == .success,
               writable.boolValue {
                let expected = (original as NSString).replacingCharacters(
                    in: NSRange(location: selection.location, length: selection.length), with: text
                )
                let status = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
                if status == .success {
                    if Self.value(element, kAXValueAttribute) as? String == expected {
                        Self.logger.info("Inserted through Accessibility")
                        return nil
                    }
                    // Avoid duplicating a successful but differently represented AX edit.
                    guard Self.value(element, kAXValueAttribute) as? String == original else {
                        Self.logger.info("AX changed the field; skipped paste fallback")
                        return "The field changed during Accessibility insertion; paste was skipped to avoid duplicating text."
                    }
                }
            }
        }

        // Electron and browser editors can replace their AX element proxy
        // while keeping the same text editor focused. Do not abandon delivery
        // before the Cmd-V fallback; use the current focused editor only while
        // the captured application remains frontmost.
        guard isSafeCurrentPasteTarget() else {
            Self.logger.info("Insertion skipped: current focus is not a safe text target")
            return "The captured field lost focus before insertion."
        }
        return await pasteIfTargetIsStillSafe()
    }

    private func isCapturedFocusCurrent() -> Bool {
        if let element {
            guard let current = Self.focused(pid), CFEqual(element, current) else { return false }
            if let original, Self.value(element, kAXValueAttribute) as? String != original { return false }
            if let selection {
                guard let current = Self.range(element),
                      current.location == selection.location,
                      current.length == selection.length else { return false }
            }
        }
        return true
    }

    private func isSafeCurrentPasteTarget() -> Bool {
        guard isTargetAppFrontmost() else { return false }
        // Without Accessibility access, the captured app is the strongest
        // available target check; System Events still verifies its PID before
        // dispatching Cmd-V.
        guard let element, let focused = Self.focused(pid) else { return true }
        if Self.isSecure(focused) { return false }
        return CFEqual(element, focused) || Self.isEditableTarget(focused)
    }

    private func isTargetAppFrontmost() -> Bool {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if let focusedPID = Self.focusedApplicationPID(), focusedPID != ownPID { return focusedPID == pid }
        if let workspacePID = NSWorkspace.shared.frontmostApplication?.processIdentifier, workspacePID != ownPID {
            return workspacePID == pid
        }
        return Self.frontmostExternalWindowPID(excluding: ownPID) == pid
    }

    private func pasteIfTargetIsStillSafe() async -> String? {
        // Web editors can replace their AX focused-element proxy while keeping
        // the same app and insertion point active. For Cmd-V, only the target
        // application and a safe current editor must remain active.
        guard isSafeCurrentPasteTarget() else {
            Self.logger.info("Paste skipped: target app or editable focus changed")
            return "The target application or text field changed before insertion."
        }

        // Post Cmd-V through the session event stream first. System Events can
        // return success after dispatch without the embedded editor accepting
        // the keystroke, which made the capsule report a false insertion.
        guard isTargetAppFrontmost(),
              let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            Self.logger.info("Quartz paste unavailable; trying System Events")
            let automation = await Task.detached { Self.sendSystemEventsPaste(to: pid) }.value
            if automation.succeeded {
                Self.logger.info("Dispatched Cmd-V through System Events fallback")
                return nil
            }
            Self.logger.error("Paste failed; Apple Event error=\(automation.errorNumber ?? 0)")
            return "Could not send Cmd-V through Quartz or System Events (Apple Event error \(automation.errorNumber ?? 0)). The text is still in the clipboard."
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        Self.logger.info("Dispatched Cmd-V through the Quartz session event stream")
        return nil
    }

    private nonisolated static func sendSystemEventsPaste(to pid: pid_t) -> (succeeded: Bool, errorNumber: Int?) {
        let source = """
        tell application "System Events"
            if (unix id of first application process whose frontmost is true) is \(pid) then
                keystroke "v" using command down
                return true
            else
                return false
            end if
        end tell
        """
        guard let script = NSAppleScript(source: source) else { return (false, nil) }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        let errorNumber = (error?["NSAppleScriptErrorNumber"] as? NSNumber)?.intValue
        return (error == nil && result.booleanValue, errorNumber)
    }

    private static func isSecure(_ element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<8 {
            guard let node = current else { break }
            if value(node, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole { return true }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            current = unsafeDowncast(parent, to: AXUIElement.self)
        }
        return false
    }

    private static func isEditableTarget(_ element: AXUIElement) -> Bool {
        let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXWebArea", "AXTextEntryArea"]
        var current: AXUIElement? = element
        for _ in 0..<8 {
            guard let node = current else { break }
            if let role = value(node, kAXRoleAttribute) as? String, textRoles.contains(role) { return true }
            if value(node, "AXEditable") as? Bool == true || supportsSelectedTextInsertion(node) { return true }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            current = unsafeDowncast(parent, to: AXUIElement.self)
        }
        return false
    }

    private static func supportsSelectedTextInsertion(_ element: AXUIElement) -> Bool {
        guard range(element) != nil, value(element, kAXValueAttribute) is String else { return false }
        var writable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &writable) == .success
            && writable.boolValue
    }

    private static func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }

    private static func focused(_ pid: pid_t) -> AXUIElement? {
        guard let result = value(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute),
              CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(result, to: AXUIElement.self)
    }

    private static func focusedApplicationPID() -> pid_t? {
        let systemWide = AXUIElementCreateSystemWide()
        guard let result = value(systemWide, kAXFocusedApplicationAttribute),
              CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        var pid: pid_t = 0
        let app = unsafeDowncast(result, to: AXUIElement.self)
        guard AXUIElementGetPid(app, &pid) == .success, pid > 0 else { return nil }
        return pid
    }

    private static func frontmostExternalWindowPID(excluding ownPID: pid_t) -> pid_t? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for window in windows {
            guard let ownerPID = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  ownerPID != ownPID,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  ((window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0) > 0.01 else { continue }
            return ownerPID
        }
        return nil
    }

    private static func range(_ element: AXUIElement) -> CFRange? {
        guard let raw = value(element, kAXSelectedTextRangeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let ax = unsafeDowncast(raw, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetValue(ax, .cfRange, &range) else { return nil }
        return range
    }
}
