import CapacityNotchCore
import AppKit
import SwiftUI

@MainActor private let openAIBlossom: NSImage = {
    let url = Bundle.main.url(forResource: "OpenAIBlossom", withExtension: "svg")
        ?? Bundle.module.url(forResource: "OpenAIBlossom", withExtension: "svg")
    guard let url,
          let image = NSImage(contentsOf: url)
    else {
        return NSImage()
    }
    return image
}()

/// Claude's burst: rays around a centre, each thinner at its tip.
struct ClaudeMark: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * 0.12
        let rayCount = 11
        let baseHalfWidth = outer * 0.115
        let tipHalfWidth = baseHalfWidth * 0.34

        var path = Path()
        for index in 0 ..< rayCount {
            let angle = Double(index) / Double(rayCount) * 2 * .pi
            let along = CGVector(dx: cos(angle), dy: sin(angle))
            let across = CGVector(dx: -along.dy, dy: along.dx)

            func point(_ distance: CGFloat, _ offset: CGFloat) -> CGPoint {
                CGPoint(
                    x: center.x + along.dx * distance + across.dx * offset,
                    y: center.y + along.dy * distance + across.dy * offset
                )
            }

            path.move(to: point(inner, -baseHalfWidth))
            path.addLine(to: point(outer, -tipHalfWidth))
            path.addLine(to: point(outer, tipHalfWidth))
            path.addLine(to: point(inner, baseHalfWidth))
            path.closeSubpath()
        }
        return path
    }
}

/// OpenCode's mark, from its own brand assets (MIT; THIRD_PARTY_NOTICES):
/// the frame and the block in its lower half, in its 240 × 300 box, kept to
/// one colour with the block a shade of it, as the dark original has it.
struct OpenCodeMark: View {
    var body: some View {
        ZStack {
            OpenCodeShape(part: .block).opacity(0.3)
            OpenCodeShape(part: .frame).fill(style: FillStyle(eoFill: true))
        }
    }
}

private struct OpenCodeShape: Shape {
    enum Part { case frame, block }
    let part: Part

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / 240, rect.height / 300)
        let origin = CGPoint(x: rect.midX - 120 * scale, y: rect.midY - 150 * scale)
        func box(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
            CGRect(x: origin.x + x * scale, y: origin.y + y * scale, width: width * scale, height: height * scale)
        }
        var path = Path()
        switch part {
        case .frame:
            path.addRect(box(0, 0, 240, 300))
            path.addRect(box(60, 60, 120, 180))
        case .block:
            path.addRect(box(60, 120, 120, 120))
        }
        return path
    }
}

struct ProviderMark: View {
    let provider: Provider
    var size: CGFloat = 16

    var body: some View {
        Group {
            switch provider {
            case .codex:
                // Drawn as a template, so it takes whatever colour it is
                // given: white on the surface, ink in light-mode Settings.
                Image(nsImage: openAIBlossom)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
            case .claudeCode:
                ClaudeMark()
            case .openCode:
                OpenCodeMark()
            }
        }
        // Every mark occupies the same box. Giving one a larger box to
        // compensate for its artwork made its card's header taller than the
        // other's, and pushed everything under it down.
        .frame(width: size, height: size)
    }
}
