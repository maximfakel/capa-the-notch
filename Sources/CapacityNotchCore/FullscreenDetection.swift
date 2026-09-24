import CoreGraphics

/// One on-screen window, as `CGWindowListCopyWindowInfo` describes it without
/// Screen Recording: its level, its owner, and its bounds in global display
/// coordinates (origin at the top left of the main display).
public struct ScreenWindow: Equatable, Sendable {
    public let level: Int
    public let owner: String
    public let bounds: CGRect

    public init(level: Int, owner: String, bounds: CGRect) {
        self.level = level
        self.owner = owner
        self.bounds = bounds
    }
}

/// Whether the display the surface sits on is showing a fullscreen
/// application.
///
/// Measured on macOS 26.6, not assumed. A fullscreen window spans the display's
/// width and reaches its bottom edge, starting at the top or just under the
/// camera housing — alone, or stacked with its application's other windows —
/// which a zoomed window can also do. What a zoomed window
/// cannot do is take the desktop away: a fullscreen Space has no wallpaper and
/// no desktop icons, while every ordinary Space has at least one of them. The
/// Dock and the Window Server keep windows at desktop levels in both, so they
/// do not count.
public enum FullscreenDetection {
    public static func isFullscreen(
        windows: [ScreenWindow],
        screen: CGRect,
        menuBarHeight: CGFloat,
        desktopIconLevel: Int
    ) -> Bool {
        let onScreen = windows.filter { $0.bounds.intersects(screen) }

        // One application's full-width windows, stacked, reaching from the
        // top to the bottom. Chrome is not one window when fullscreen: its tab
        // strip, its toolbar and the page are separate windows one under
        // another, and none of them spans the display on its own.
        let spanning = Dictionary(grouping: onScreen.filter { window in
            window.level == 0
                && window.bounds.minX <= screen.minX
                && window.bounds.maxX >= screen.maxX
        }, by: \.owner)
        let covered = spanning.values.contains { windows in
            var reached = screen.minY + menuBarHeight + 1
            for window in windows.sorted(by: { $0.bounds.minY < $1.bounds.minY }) {
                guard window.bounds.minY <= reached else { break }
                reached = max(reached, window.bounds.maxY)
            }
            return reached >= screen.maxY
        }
        guard covered else { return false }

        let desktopShows = onScreen.contains { window in
            window.level <= desktopIconLevel
                && window.owner != "Dock"
                && window.owner != "Window Server"
        }
        return !desktopShows
    }
}
