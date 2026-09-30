import SwiftUI

/// Settings' icons, drawn as the Paper mockup draws them ("Pairtask" /
/// "Settings"): outlines on a 16-point grid, 1.3 points wide, round caps.
/// The author preferred them to SF Symbols.
enum SettingsIcon {
    case general
    case providers
    case alerts
    case modules
    case diagnostics
    case music
    case teleprompter
    case dictation
    /// A tray: the Shelf.
    case shelf
    /// A screen with its notch: onboarding's first step.
    case notch
    /// A padlock: onboarding's permissions.
    case permissions
    /// The figure macOS draws for Accessibility.
    case accessibility
    /// A key on a keyboard: System Events pressing ⌘V.
    case automation
    case refresh
    case chevrons

    /// The grid the drawing's paths are written on.
    fileprivate var grid: CGSize {
        switch self {
        case .refresh: CGSize(width: 14, height: 14)
        case .chevrons: CGSize(width: 10, height: 12)
        default: CGSize(width: 16, height: 16)
        }
    }

    fileprivate var lineWidth: CGFloat {
        switch self {
        case .chevrons: 1.2
        case .music, .teleprompter, .dictation, .permissions, .shelf: 1.4
        default: 1.3
        }
    }

    /// The outline, in grid points. y runs down, as in the SVG.
    fileprivate var stroke: Path {
        var path = Path()
        switch self {
        case .general:
            path.addEllipse(in: CGRect(x: 8 - 2.25, y: 8 - 2.25, width: 4.5, height: 4.5))
            for (from, to) in [
                ((8.0, 1.75), (8.0, 3.25)), ((8.0, 12.75), (8.0, 14.25)),
                ((14.25, 8.0), (12.75, 8.0)), ((3.25, 8.0), (1.75, 8.0)),
                ((12.42, 3.58), (11.36, 4.64)), ((4.64, 11.36), (3.58, 12.42)),
                ((12.42, 12.42), (11.36, 11.36)), ((4.64, 4.64), (3.58, 3.58)),
            ] {
                path.move(to: CGPoint(x: from.0, y: from.1))
                path.addLine(to: CGPoint(x: to.0, y: to.1))
            }
        case .providers:
            // The dial's upper half, then the needle.
            path.addArc(center: CGPoint(x: 8, y: 11.5), radius: 5.5,
                        startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            path.move(to: CGPoint(x: 8, y: 11.5))
            path.addLine(to: CGPoint(x: 10.5, y: 8))
        case .alerts:
            path.move(to: CGPoint(x: 4, y: 11))
            path.addLine(to: CGPoint(x: 4, y: 7.5))
            path.addArc(center: CGPoint(x: 8, y: 7.5), radius: 4,
                        startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            path.addLine(to: CGPoint(x: 12, y: 11))
            path.addLine(to: CGPoint(x: 13, y: 12.25))
            path.addLine(to: CGPoint(x: 3, y: 12.25))
            path.closeSubpath()
            path.move(to: CGPoint(x: 6.75, y: 14))
            path.addLine(to: CGPoint(x: 9.25, y: 14))
        case .modules:
            for origin in [(2.0, 2.0), (9.0, 2.0), (2.0, 9.0), (9.0, 9.0)] {
                path.addRoundedRect(
                    in: CGRect(x: origin.0, y: origin.1, width: 5, height: 5),
                    cornerSize: CGSize(width: 1.5, height: 1.5)
                )
            }
        case .diagnostics:
            path.move(to: CGPoint(x: 1.75, y: 8))
            for point in [(4.25, 8.0), (5.75, 4.0), (8.25, 12.0), (9.75, 8.0), (14.25, 8.0)] {
                path.addLine(to: CGPoint(x: point.0, y: point.1))
            }
        case .music:
            path.move(to: CGPoint(x: 6, y: 12))
            path.addLine(to: CGPoint(x: 6, y: 3.5))
            path.addLine(to: CGPoint(x: 13, y: 2))
            path.addLine(to: CGPoint(x: 13, y: 10.5))
            path.addEllipse(in: CGRect(x: 4.5 - 1.75, y: 12 - 1.75, width: 3.5, height: 3.5))
            path.addEllipse(in: CGRect(x: 11.5 - 1.75, y: 10.5 - 1.75, width: 3.5, height: 3.5))
        case .teleprompter:
            // Three lines of a Script, the last one short: the mockup's tile.
            for (y, end) in [(4.5, 13.0), (8.0, 13.0), (11.5, 9.0)] {
                path.move(to: CGPoint(x: 3, y: y))
                path.addLine(to: CGPoint(x: end, y: y))
            }
        case .dictation:
            path.addRoundedRect(
                in: CGRect(x: 5.75, y: 1.75, width: 4.5, height: 7.5),
                cornerSize: CGSize(width: 2.25, height: 2.25)
            )
            path.move(to: CGPoint(x: 3.5, y: 7.25))
            path.addQuadCurve(to: CGPoint(x: 12.5, y: 7.25), control: CGPoint(x: 8, y: 16.25))
            path.move(to: CGPoint(x: 8, y: 11.75))
            path.addLine(to: CGPoint(x: 8, y: 14.25))
        case .shelf:
            // The tray's rim, its dip, and its sides going up and in.
            path.move(to: CGPoint(x: 1.75, y: 9.25))
            path.addLine(to: CGPoint(x: 5.25, y: 9.25))
            path.addLine(to: CGPoint(x: 6.25, y: 11))
            path.addLine(to: CGPoint(x: 9.75, y: 11))
            path.addLine(to: CGPoint(x: 10.75, y: 9.25))
            path.addLine(to: CGPoint(x: 14.25, y: 9.25))
            path.move(to: CGPoint(x: 1.75, y: 9.25))
            path.addLine(to: CGPoint(x: 1.75, y: 12.25))
            path.addQuadCurve(to: CGPoint(x: 3.5, y: 14), control: CGPoint(x: 1.75, y: 14))
            path.addLine(to: CGPoint(x: 12.5, y: 14))
            path.addQuadCurve(to: CGPoint(x: 14.25, y: 12.25), control: CGPoint(x: 14.25, y: 14))
            path.addLine(to: CGPoint(x: 14.25, y: 9.25))
            path.move(to: CGPoint(x: 1.75, y: 9.25))
            path.addLine(to: CGPoint(x: 3.5, y: 3.9))
            path.addQuadCurve(to: CGPoint(x: 4.9, y: 3), control: CGPoint(x: 3.8, y: 3))
            path.addLine(to: CGPoint(x: 11.1, y: 3))
            path.addQuadCurve(to: CGPoint(x: 12.5, y: 3.9), control: CGPoint(x: 12.2, y: 3))
            path.addLine(to: CGPoint(x: 14.25, y: 9.25))
        case .notch:
            // The screen's outline dips round the notch at the top.
            path.move(to: CGPoint(x: 6, y: 2.75))
            path.addLine(to: CGPoint(x: 3.25, y: 2.75))
            path.addQuadCurve(to: CGPoint(x: 1.75, y: 4.25), control: CGPoint(x: 1.75, y: 2.75))
            path.addLine(to: CGPoint(x: 1.75, y: 11.75))
            path.addQuadCurve(to: CGPoint(x: 3.25, y: 13.25), control: CGPoint(x: 1.75, y: 13.25))
            path.addLine(to: CGPoint(x: 12.75, y: 13.25))
            path.addQuadCurve(to: CGPoint(x: 14.25, y: 11.75), control: CGPoint(x: 14.25, y: 13.25))
            path.addLine(to: CGPoint(x: 14.25, y: 4.25))
            path.addQuadCurve(to: CGPoint(x: 12.75, y: 2.75), control: CGPoint(x: 14.25, y: 2.75))
            path.addLine(to: CGPoint(x: 10, y: 2.75))
            path.addLine(to: CGPoint(x: 10, y: 3.75))
            path.addQuadCurve(to: CGPoint(x: 9, y: 4.75), control: CGPoint(x: 10, y: 4.75))
            path.addLine(to: CGPoint(x: 7, y: 4.75))
            path.addQuadCurve(to: CGPoint(x: 6, y: 3.75), control: CGPoint(x: 6, y: 4.75))
            path.closeSubpath()
        case .permissions:
            path.addRoundedRect(
                in: CGRect(x: 3, y: 7, width: 10, height: 7.25),
                cornerSize: CGSize(width: 1.75, height: 1.75)
            )
            path.move(to: CGPoint(x: 5.25, y: 7))
            path.addLine(to: CGPoint(x: 5.25, y: 4.75))
            path.addArc(center: CGPoint(x: 8, y: 4.75), radius: 2.75,
                        startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            path.addLine(to: CGPoint(x: 10.75, y: 7))
            path.move(to: CGPoint(x: 8, y: 10))
            path.addLine(to: CGPoint(x: 8, y: 11.25))
        case .accessibility:
            path.addEllipse(in: CGRect(x: 1.75, y: 1.75, width: 12.5, height: 12.5))
            path.addEllipse(in: CGRect(x: 7.1, y: 3.85, width: 1.8, height: 1.8))
            path.move(to: CGPoint(x: 4.75, y: 6.75))
            path.addLine(to: CGPoint(x: 11.25, y: 6.75))
            path.move(to: CGPoint(x: 8, y: 6.75))
            path.addLine(to: CGPoint(x: 8, y: 9.25))
            path.addLine(to: CGPoint(x: 6.25, y: 12))
            path.move(to: CGPoint(x: 8, y: 9.25))
            path.addLine(to: CGPoint(x: 9.75, y: 12))
        case .automation:
            path.addRoundedRect(
                in: CGRect(x: 1.75, y: 3.75, width: 12.5, height: 8.5),
                cornerSize: CGSize(width: 1.75, height: 1.75)
            )
            for x in [4.5, 6.75, 9.25, 11.5] {
                path.move(to: CGPoint(x: x, y: 6.5))
                path.addLine(to: CGPoint(x: x + 0.01, y: 6.5))
            }
            path.move(to: CGPoint(x: 5.5, y: 9.5))
            path.addLine(to: CGPoint(x: 10.5, y: 9.5))
        case .refresh:
            // Most of a circle from three o'clock round to half past one,
            // and the arrowhead at its end.
            path.addArc(center: CGPoint(x: 7, y: 7), radius: 4.5,
                        startAngle: .degrees(0), endAngle: .degrees(-45), clockwise: false)
            path.move(to: CGPoint(x: 10.5, y: 1.75))
            path.addLine(to: CGPoint(x: 10.5, y: 4.25))
            path.addLine(to: CGPoint(x: 8, y: 4.25))
        case .chevrons:
            path.move(to: CGPoint(x: 2.5, y: 4.25))
            path.addLine(to: CGPoint(x: 5, y: 1.75))
            path.addLine(to: CGPoint(x: 7.5, y: 4.25))
            path.move(to: CGPoint(x: 2.5, y: 7.75))
            path.addLine(to: CGPoint(x: 5, y: 10.25))
            path.addLine(to: CGPoint(x: 7.5, y: 7.75))
        }
        return path
    }

    /// Filled parts: the dial's hub.
    fileprivate var fill: Path? {
        guard case .providers = self else { return nil }
        return Path(ellipseIn: CGRect(x: 7, y: 10.5, width: 2, height: 2))
    }
}

/// One icon at the drawing's size, in the current foreground colour.
struct SettingsIconView: View {
    let icon: SettingsIcon

    init(_ icon: SettingsIcon) {
        self.icon = icon
    }

    var body: some View {
        Canvas { context, size in
            let scale = CGAffineTransform(
                scaleX: size.width / icon.grid.width,
                y: size.height / icon.grid.height
            )
            let shading = GraphicsContext.Shading.foreground
            context.stroke(
                icon.stroke.applying(scale),
                with: shading,
                style: StrokeStyle(lineWidth: icon.lineWidth, lineCap: .round, lineJoin: .round)
            )
            if let fill = icon.fill {
                context.fill(fill.applying(scale), with: shading)
            }
        }
        .frame(width: icon.grid.width, height: icon.grid.height)
        .accessibilityHidden(true)
    }
}
