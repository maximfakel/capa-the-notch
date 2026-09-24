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
    /// Whether the display the surface sits on shows a fullscreen application.
    @Published private(set) var isFullscreen = false

    private let preferredDisplayKey = "preferredDisplayID"
    private var observers: [NSObjectProtocol] = []
    private var pendingChecks: [DispatchWorkItem] = []

    init() {
        geometry = Self.measure(on: Self.chosenScreen(preferred: Self.storedPreference()))
        watchFullscreen()
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
        checkFullscreen()
    }

    // MARK: - Fullscreen

    /// Asked again whenever the Space or the frontmost application changes,
    /// rather than on a timer: entering fullscreen, leaving it, and a video
    /// taking the screen all change the Space. The window is still animating
    /// when the notice arrives, so the question is asked again as it settles.
    private func watchFullscreen() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didActivateApplicationNotification,
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkFullscreenAsItSettles() }
            })
        }
        checkFullscreen()
    }

    private func checkFullscreenAsItSettles() {
        pendingChecks.forEach { $0.cancel() }
        pendingChecks = [0, 0.4, 1.2].map { delay in
            let check = DispatchWorkItem { [weak self] in self?.checkFullscreen() }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: check)
            return check
        }
    }

    private func checkFullscreen() {
        let fullscreen = screen.map { Self.showsFullscreen($0, menuBarHeight: geometry.menuBarHeight) } ?? false
        if fullscreen != isFullscreen { isFullscreen = fullscreen }
    }

    private static func showsFullscreen(_ screen: NSScreen, menuBarHeight: CGFloat) -> Bool {
        guard
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]],
            let main = NSScreen.screens.first
        else { return false }

        let ownPID = Int(ProcessInfo.processInfo.processIdentifier)
        let windows: [ScreenWindow] = list.compactMap { info in
            guard
                (info[kCGWindowOwnerPID as String] as? Int) != ownPID,
                let level = info[kCGWindowLayer as String] as? Int,
                let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsInfo)
            else { return nil }
            return ScreenWindow(level: level, owner: info[kCGWindowOwnerName as String] as? String ?? "", bounds: bounds)
        }

        // AppKit counts from the bottom of the main display, the window list
        // from its top.
        let frame = screen.frame
        let display = CGRect(
            x: frame.minX,
            y: main.frame.maxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
        return FullscreenDetection.isFullscreen(
            windows: windows,
            screen: display,
            menuBarHeight: menuBarHeight,
            desktopIconLevel: Int(CGWindowLevelForKey(.desktopIconWindow))
        )
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
