import CoreGraphics

/// The surface's outline as one path: square along the top, where it meets
/// the menu bar, with a shoulder curving out into the menu bar either side,
/// rounded along the bottom. y runs down.
public enum SurfaceOutline {
    /// The inside curve where the shape meets the menu bar either side:
    /// twenty points, drawn outside the shape.
    public static let shoulder: CGFloat = 20

    /// - Parameters:
    ///   - size: the strip, or the whole surface when it is open.
    ///   - radius: the bottom corners of `size`.
    public static func path(in rect: CGRect, size: CGSize, radius: CGFloat) -> CGPath {
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
