import CoreGraphics

/// The shape of the strip Capacity Notch shares with the menu bar.
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

    /// The closed surface: the notch, with room for one Provider's figure on
    /// each side and no more. It is narrower than the open one, so opening
    /// widens as well as lengthens — the content is laid out at the open
    /// width throughout and centred, so nothing is re-flowed by the motion.
    public static let minimumCompactWidth: CGFloat = 422

    public func compactWidth(providerWidth: CGFloat = 101) -> CGFloat {
        min(
            max(notchWidth + providerWidth * 2, Self.minimumCompactWidth),
            surfaceWidth()
        )
    }
}
