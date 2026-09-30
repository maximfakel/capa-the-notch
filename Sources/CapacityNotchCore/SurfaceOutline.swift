import CoreGraphics

/// The surface's outline as one path: square along the top, where it meets
/// the menu bar, with a shoulder curving out into the menu bar either side,
/// rounded along the bottom — and, while a file is held over the closed
/// notch, a tab hanging beneath it for the Shelf, joined to the strip by
/// inverse corners that are part of the same outline, not shapes laid beside
/// it ("Notch — Compact — Dropping on the Shelf"). y runs down.
public enum SurfaceOutline {
    /// The inside curve where the shape meets the menu bar either side:
    /// twenty points, drawn outside the shape.
    public static let shoulder: CGFloat = 20
    /// Where the tab meets the strip, the curve out into it.
    public static let tabJoin: CGFloat = 12
    /// The tab's own bottom corners.
    public static let tabCorner: CGFloat = 24

    /// - Parameters:
    ///   - size: the strip, or the whole surface when it is open.
    ///   - radius: the bottom corners of `size`.
    ///   - tab: the drop tab under it, centred; `.zero` for none.
    public static func path(in rect: CGRect, size: CGSize, radius: CGFloat, tab: CGSize = .zero) -> CGPath {
        let path = CGMutablePath()
        guard size.width > 0, size.height > 0 else { return path }
        let x0 = rect.midX - size.width / 2, x1 = x0 + size.width
        let top = rect.minY, bottom = top + size.height
        let r = min(shoulder, size.height, size.width / 2)
        // A shoulder and a corner share the side: on a strip too short for
        // both, the corner gives way and the side is one curve.
        let corner = max(0, min(radius, size.width / 2, size.height - r))
        let unit = r / 12, arc = corner * 0.552

        path.move(to: CGPoint(x: x0 - r, y: top))
        // The drawing's own curve, flat along the menu bar and steep down the side.
        path.addCurve(to: CGPoint(x: x0, y: top + r),
                      control1: CGPoint(x: x0 - 0.529 * unit, y: top),
                      control2: CGPoint(x: x0 - 0.211 * unit, y: top + 7.2 * unit))
        path.addLine(to: CGPoint(x: x0, y: bottom - corner))
        path.addCurve(to: CGPoint(x: x0 + corner, y: bottom),
                      control1: CGPoint(x: x0, y: bottom - corner + arc),
                      control2: CGPoint(x: x0 + corner - arc, y: bottom))

        // The tab, when there is one and room for it between the corners.
        let join = min(tabJoin, tab.height / 2)
        let tabWidth = min(tab.width, size.width - 2 * (corner + join))
        if tab.height > 0, tabWidth > 0, join > 0 {
            let t0 = rect.midX - tabWidth / 2, t1 = t0 + tabWidth
            let tabBottom = bottom + tab.height
            let tabRound = max(0, min(tabCorner, tabWidth / 2, tab.height - join))
            let joinArc = join * 0.552, tabArc = tabRound * 0.552
            path.addLine(to: CGPoint(x: t0 - join, y: bottom))
            // Out of the strip's bottom and down the tab's side, bending the
            // other way from every other corner.
            path.addCurve(to: CGPoint(x: t0, y: bottom + join),
                          control1: CGPoint(x: t0 - join + joinArc, y: bottom),
                          control2: CGPoint(x: t0, y: bottom + join - joinArc))
            path.addLine(to: CGPoint(x: t0, y: tabBottom - tabRound))
            path.addCurve(to: CGPoint(x: t0 + tabRound, y: tabBottom),
                          control1: CGPoint(x: t0, y: tabBottom - tabRound + tabArc),
                          control2: CGPoint(x: t0 + tabRound - tabArc, y: tabBottom))
            path.addLine(to: CGPoint(x: t1 - tabRound, y: tabBottom))
            path.addCurve(to: CGPoint(x: t1, y: tabBottom - tabRound),
                          control1: CGPoint(x: t1 - tabRound + tabArc, y: tabBottom),
                          control2: CGPoint(x: t1, y: tabBottom - tabRound + tabArc))
            path.addLine(to: CGPoint(x: t1, y: bottom + join))
            path.addCurve(to: CGPoint(x: t1 + join, y: bottom),
                          control1: CGPoint(x: t1, y: bottom + join - joinArc),
                          control2: CGPoint(x: t1 + join - joinArc, y: bottom))
        }

        path.addLine(to: CGPoint(x: x1 - corner, y: bottom))
        path.addCurve(to: CGPoint(x: x1, y: bottom - corner),
                      control1: CGPoint(x: x1 - corner + arc, y: bottom),
                      control2: CGPoint(x: x1, y: bottom - corner + arc))
        path.addLine(to: CGPoint(x: x1, y: top + r))
        path.addCurve(to: CGPoint(x: x1 + r, y: top),
                      control1: CGPoint(x: x1 + 0.211 * unit, y: top + 7.2 * unit),
                      control2: CGPoint(x: x1 + 0.529 * unit, y: top))
        path.closeSubpath()
        return path
    }
}
