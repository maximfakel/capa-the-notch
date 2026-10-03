import CoreGraphics

/// The shape of the strip CapaTheNotch shares with the menu bar.
///
/// The compact surface belongs to that strip, so it takes its height from the
/// menu bar rather than from a number chosen by eye, and it keeps its content
/// clear of the physical notch rather than hiding numbers behind it.
public struct NotchGeometry: Equatable, Sendable {
    public let menuBarHeight: CGFloat
    /// Zero on a display without a notch.
    public let notchWidth: CGFloat

    public init(menuBarHeight: CGFloat, notchWidth: CGFloat) {
        self.menuBarHeight = menuBarHeight
        self.notchWidth = notchWidth
    }

    /// The room every open page has under the strip, whatever it shows, so
    /// the surface does not change height as pages turn ("Limits — C ·
    /// Gauges", "Expanded — Playing", "Expanded — Shelf").
    public static let pageHeight: CGFloat = 152
    /// The page dots under it, at rest: the switcher's eight points and the
    /// four above and eight below it (`PageSwitcher`).
    public static let pageSwitcherHeight: CGFloat = 20
    /// What a reading Teleprompter adds under the strip while closed: as tall
    /// as an open page and its dots ("Compact — Teleprompter running").
    public static let compactTeleprompterRow: CGFloat = pageHeight + pageSwitcherHeight

    /// The open surface: 210 under the drawing's 38-point menu bar.
    public var openHeight: CGFloat {
        menuBarHeight + Self.pageHeight + Self.pageSwitcherHeight
    }

    /// - Parameters:
    ///   - safeAreaTop: `NSScreen.safeAreaInsets.top`, which is the notch
    ///     height on a notched display and zero elsewhere.
    ///   - auxiliaryTopLeftWidth: the width of `NSScreen.auxiliaryTopLeftArea`,
    ///     the usable menu bar to the left of the notch.
    ///   - statusBarThickness: the fallback for a display with no notch.
    public static func measure(
        screenWidth: CGFloat,
        safeAreaTop: CGFloat,
        auxiliaryTopLeftWidth: CGFloat?,
        statusBarThickness: CGFloat
    ) -> NotchGeometry {
        let height = safeAreaTop > 0 ? safeAreaTop : statusBarThickness

        guard
            let sideWidth = auxiliaryTopLeftWidth,
            sideWidth > 0,
            screenWidth > sideWidth * 2
        else {
            return NotchGeometry(menuBarHeight: height, notchWidth: 0)
        }

        return NotchGeometry(menuBarHeight: height, notchWidth: screenWidth - sideWidth * 2)
    }

    /// The open surface: the notch, with room for a Provider card on each
    /// side of it.
    public static let minimumSurfaceWidth: CGFloat = 560

    public func surfaceWidth(providerWidth: CGFloat = 170) -> CGFloat {
        max(notchWidth + providerWidth * 2, Self.minimumSurfaceWidth)
    }

    /// The closed surface, as "Screen — … — Compact" draws it: 370 points
    /// over the 185-point notch a MacBook Pro has at its default scaling, and
    /// 410 over the 220-point one it has at More Space — the notch, one
    /// Provider's figure each side, twelve points to the edge. Without a notch
    /// it is the narrower. It is narrower than the open surface, so opening
    /// widens as well as lengthens — the content is laid out at the open width
    /// throughout and centred, so nothing is re-flowed by the motion.
    public static let compactWidths: (defaultScaling: CGFloat, moreSpace: CGFloat) = (370, 410)

    public func compactWidth() -> CGFloat {
        let drawn = notchWidth > 200 ? Self.compactWidths.moreSpace : Self.compactWidths.defaultScaling
        // A notch wider than either drawing still leaves a figure each side.
        return min(max(drawn, notchWidth + 185), surfaceWidth())
    }
}
