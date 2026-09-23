import AppKit
import CapacityNotchCore
import Combine

/// The shape of the strip the surface sits in, and which display it sits on.
///
/// Measured rather than assumed, and measured again whenever the displays
/// change: a menu bar is 38 points tall on a notched laptop and 22 on an
/// external screen, and a surface that kept the first number after moving to
/// the second would hang into the window below it.
@MainActor
final class SurfaceMetrics: ObservableObject {
    @Published private(set) var geometry: NotchGeometry

    private let preferredDisplayKey = "preferredDisplayID"

    init() {
        geometry = Self.measure(on: Self.chosenScreen(preferred: Self.storedPreference()))
    }

    var preferredDisplayID: UInt32? {
        get { Self.storedPreference() }
        set {
            if let newValue {
                UserDefaults.standard.set(Int(newValue), forKey: preferredDisplayKey)
            } else {
                UserDefaults.standard.removeObject(forKey: preferredDisplayKey)
            }
            refresh()
        }
    }

    var screen: NSScreen? {
        Self.chosenScreen(preferred: preferredDisplayID)
    }

    var displays: [DisplayDescriptor] {
        Self.available()
    }

    /// The display actually in use, which is not always the one preferred: a
    /// screen that has been unplugged cannot hold the surface.
    var chosenDisplay: DisplayDescriptor? {
        DisplaySelection.chosen(preferred: preferredDisplayID, available: Self.available())
    }

    func refresh() {
        geometry = Self.measure(on: screen)
    }

    private static func storedPreference() -> UInt32? {
        let stored = UserDefaults.standard.integer(forKey: "preferredDisplayID")
        return stored > 0 ? UInt32(stored) : nil
    }

    private static func measure(on screen: NSScreen?) -> NotchGeometry {
        guard let screen else {
            return NotchGeometry(menuBarHeight: NSStatusBar.system.thickness, notchWidth: 0)
        }

        return NotchGeometry.measure(
            screenWidth: screen.frame.width,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryTopLeftWidth: screen.auxiliaryTopLeftArea?.width,
            statusBarThickness: NSStatusBar.system.thickness
        )
    }

    private static func chosenScreen(preferred: UInt32?) -> NSScreen? {
        guard let choice = DisplaySelection.chosen(preferred: preferred, available: available())
        else { return NSScreen.main ?? NSScreen.screens.first }

        return NSScreen.screens.first { identifier(of: $0) == choice.id }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private static func available() -> [DisplayDescriptor] {
        NSScreen.screens.compactMap { screen in
            guard let id = identifier(of: screen) else { return nil }
            return DisplayDescriptor(
                id: id,
                name: screen.localizedName,
                isBuiltIn: CGDisplayIsBuiltin(CGDirectDisplayID(id)) != 0
            )
        }
    }

    private static func identifier(of screen: NSScreen) -> UInt32? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }
}
