import AppKit
import CapacityNotchCore
import SwiftUI
import UniformTypeIdentifiers

/// Paper "Notch — Expanded — Shelf" and "— Shelf empty": the Shelf as a page
/// of the open surface.
struct ShelfPage: View {
    @ObservedObject var shelf: ShelfController
    @ObservedObject var pointer: SurfacePointer
    /// Whether the page can be seen, so a moved file is noticed when it is.
    var isVisible = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(L("Shelf"))
                    .font(SurfaceType.geist(15, .semibold))
                    .foregroundStyle(.white)
                Text(shelf.items.isEmpty ? L("empty") : Localization.fileCount(shelf.items.count))
                    .font(SurfaceType.geist(12))
                    .foregroundStyle(SurfaceType.captionColour)
                Spacer(minLength: 0)
                if !shelf.items.isEmpty {
                    Button(L("Clear")) { shelf.clear() }
                        .buttonStyle(.plain)
                        .font(SurfaceType.geist(13, .medium))
                        .foregroundStyle(SurfaceType.captionColour)
                }
            }

            if shelf.items.isEmpty {
                ShelfEmptyZone()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(shelf.items) { item in
                            ShelfTile(
                                item: item,
                                isMissing: shelf.missing.contains(item.id),
                                thumbnail: shelf.thumbnails[item.id],
                                pointer: pointer,
                                remove: { shelf.remove(item.id) },
                                dragEnded: { shelf.refreshAvailability() }
                            )
                        }
                    }
                    // Room for the ✕ that stands out of a tile's corner.
                    .padding(.top, 6)
                    .padding(.trailing, 6)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .onAppear { shelf.refreshAvailability() }
        .onChange(of: isVisible) { _, visible in if visible { shelf.refreshAvailability() } }
    }
}

/// One file: its thumbnail or a page with its extension, its name in two
/// lines cut in the middle as Finder cuts it, and ✕ under the pointer. A file
/// moved or deleted since is dimmed and dashed, and cannot be dragged.
private struct ShelfTile: View {
    let item: ShelfItem
    let isMissing: Bool
    let thumbnail: NSImage?
    @ObservedObject var pointer: SurfacePointer
    let remove: () -> Void
    let dragEnded: () -> Void

    private static let width: CGFloat = 76

    var body: some View {
        PointerInside(pointer: pointer) { hovered in
            VStack(spacing: 6) {
                preview
                    // Dragged as Finder drags a file: the file itself, which
                    // the destination moves on the same disk and copies
                    // across disks — never a new file written from its data.
                    .overlay {
                        if !isMissing { FileDragSource(item: item, ended: dragEnded) }
                    }
                    .overlay(alignment: .topTrailing) {
                        if hovered {
                            Button(action: remove) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 18, height: 18)
                                    .background(Circle().fill(Color(white: 0x3A / 255)))
                                    .overlay(Circle().strokeBorder(Color.black, lineWidth: 2).padding(-2))
                            }
                            .buttonStyle(.plain)
                            .offset(x: 5, y: -5)
                            .accessibilityLabel(L("Remove %@ from the Shelf", item.name))
                        }
                    }
                Text(item.name)
                    .font(SurfaceType.geist(11))
                    .foregroundStyle(isMissing ? Color.white.opacity(0x59 / 255) : .white)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                    .frame(width: Self.width)
            }
        }
        .frame(width: Self.width)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isMissing ? L("%@, moved", item.name) : item.name)
    }

    private var preview: some View {
        let kind = item.kind
        return ZStack {
            if isMissing {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0x40 / 255), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                PageGlyph().fill(Color.white.opacity(0.18))
                    .frame(width: 30, height: 38)
                // Said on the file itself, where the eye looks for it.
                Text(L("File\nmoved"))
                    .font(SurfaceType.geist(10))
                    .foregroundStyle(SurfaceType.orange)
                    .multilineTextAlignment(.center)
                    .fixedSize()
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0x1F / 255))
                if kind == .image, let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 56, height: 38)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
                } else {
                    PageGlyph().fill(Color.white.opacity(0.92))
                        .frame(width: 30, height: 38)
                        .overlay(alignment: .bottom) {
                            if let badge = kind.badge(forName: item.name) {
                                Text(badge)
                                    .font(SurfaceType.geist(8, .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 3)
                                    .frame(height: 11)
                                    .background(RoundedRectangle(cornerRadius: 3).fill(kind.colour))
                                    .fixedSize()
                                    .offset(y: -2)
                            }
                        }
                }
            }
        }
        .frame(width: Self.width, height: 64)
    }
}

/// Starts a drag of one thing from the Shelf: a file as its own URL, as
/// Finder drags it; an image held in memory as a promise, written where it
/// is dropped and nowhere before.
private struct FileDragSource: NSViewRepresentable {
    let item: ShelfItem
    let ended: () -> Void

    func makeNSView(context: Context) -> FileDragView {
        let view = FileDragView()
        view.item = item
        view.ended = ended
        return view
    }

    func updateNSView(_ view: FileDragView, context: Context) {
        view.item = item
        view.ended = ended
    }
}

private final class FileDragView: NSView, NSDraggingSource, NSFilePromiseProviderDelegate {
    var item: ShelfItem?
    var ended: () -> Void = {}
    private var pressedAt: NSPoint?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        pressedAt = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let item, let start = pressedAt else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) > 3 else { return }
        pressedAt = nil
        let dragged: NSDraggingItem
        let icon: NSImage
        switch item.content {
        case let .file(url):
            dragged = NSDraggingItem(pasteboardWriter: url as NSURL)
            icon = NSWorkspace.shared.icon(forFile: url.path)
        case let .inMemory(name, data):
            let type = UTType(filenameExtension: (name as NSString).pathExtension) ?? .png
            dragged = NSDraggingItem(pasteboardWriter: NSFilePromiseProvider(fileType: type.identifier, delegate: self))
            icon = NSImage(data: data) ?? NSWorkspace.shared.icon(for: type)
        }
        let side: CGFloat = 48
        dragged.setDraggingFrame(NSRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side), contents: icon)
        beginDraggingSession(with: [dragged], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        pressedAt = nil
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Onto the Shelf itself it would only rise to the front; elsewhere
        // the destination chooses, as it does for a drag from Finder.
        context == .outsideApplication ? [.move, .copy, .generic, .link] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // Finder moves a file a moment after the drop; look again once it has.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [ended] in ended() }
    }

    // MARK: An image written where it is dropped

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        item?.name ?? "Image.png"
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        guard case let .inMemory(_, data)? = item?.content else {
            completionHandler(CocoaError(.fileNoSuchFile))
            return
        }
        do {
            try data.write(to: url)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }
}

/// A page with its corner folded, on the drawing's 30 by 38.
private struct PageGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 30, sy = rect.height / 38
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy) }
        var path = Path()
        path.move(to: p(4, 1))
        path.addLine(to: p(19, 1))
        path.addLine(to: p(29, 11))
        path.addLine(to: p(29, 33))
        path.addQuadCurve(to: p(25, 37), control: p(29, 37))
        path.addLine(to: p(4, 37))
        path.addQuadCurve(to: p(0, 33), control: p(0, 37))
        path.addLine(to: p(0, 5))
        path.addQuadCurve(to: p(4, 1), control: p(0, 1))
        path.closeSubpath()
        return path
    }
}

private extension ShelfFileKind {
    var colour: Color {
        switch self {
        case .pdf: SurfaceType.red
        case .presentation: SurfaceType.orange
        case .document: Color(red: 0x0A / 255, green: 0x84 / 255, blue: 0xFF / 255)
        case .spreadsheet: SurfaceType.green
        case .archive, .image, .other: Color(white: 0x8E / 255)
        }
    }
}

/// An arrow into a tray, the drawing's drop sign.
private struct DropGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 22
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        path.move(to: p(11, 3)); path.addLine(to: p(11, 14))
        path.move(to: p(6.5, 9.5)); path.addLine(to: p(11, 14)); path.addLine(to: p(15.5, 9.5))
        path.move(to: p(4, 16)); path.addLine(to: p(4, 17.5))
        path.addQuadCurve(to: p(5.5, 19), control: p(4, 19))
        path.addLine(to: p(16.5, 19))
        path.addQuadCurve(to: p(18, 17.5), control: p(18, 19))
        path.addLine(to: p(18, 16))
        return path
    }
}

private struct ShelfEmptyZone: View {
    var body: some View {
        VStack(spacing: 6) {
            DropGlyph()
                .stroke(SurfaceType.captionColour, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                .frame(width: 22, height: 22)
            Text(L("Drag files here to keep them at hand"))
                .font(SurfaceType.geist(13, .medium))
                .foregroundStyle(.white)
            Text(L("Up to 20 files. The Shelf empties when Capacity Notch quits."))
                .font(SurfaceType.geist(11))
                .foregroundStyle(SurfaceType.captionColour)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 95)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0x40 / 255), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
        )
    }
}

/// Paper "Notch — Compact — Dropping on the Shelf": what the drop tab under
/// the closed strip holds while a file is over it.
struct ShelfDropZone: View {
    /// The tab's size, which the outline draws; this fills it.
    static let tab = CGSize(width: 196, height: 126)

    var body: some View {
        VStack(spacing: 12) {
            DropGlyph()
                .stroke(.white, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                .frame(width: 16, height: 16)
            Text(L("Release to put it\non the Shelf"))
                .font(SurfaceType.geist(11))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
        }
        .frame(width: 160, height: 100)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0xB3 / 255), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
        )
        .padding(.top, 8)
        .padding(.horizontal, 18)
        .padding(.bottom, 18)
        .frame(width: Self.tab.width, height: Self.tab.height, alignment: .top)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Hover from the panel's pointer

/// Whether the pointer is over this view, from `SurfacePointer`, widened by
/// `margin` either way.
struct PointerInside<Content: View>: View {
    @ObservedObject var pointer: SurfacePointer
    var margin = CGSize.zero
    @ViewBuilder let content: (Bool) -> Content

    private let _frame = State<CGRect>(initialValue: .zero)

    var body: some View {
        let frame = _frame.wrappedValue.insetBy(dx: -margin.width, dy: -margin.height)
        let inside = pointer.location.map { frame.contains($0) } ?? false
        content(inside)
            .background(
                GeometryReader { geometry in
                    let measured = geometry.frame(in: .named(SurfacePointer.space))
                    Color.clear
                        .onAppear { _frame.wrappedValue = measured }
                        .onChange(of: measured) { _, now in _frame.wrappedValue = now }
                }
            )
    }
}

// MARK: - The page switcher

/// Paper "Notch — Page switcher — States". At rest the pages are dots; when
/// the pointer comes near — the panel decides, and lets the surface down by
/// `growth` to make room — each dot grows into its button, its page's icon
/// coming up inside it, on the surface's own spring. The buttons light under
/// the pointer with the page's name above, shrink a little when pressed, ring
/// under keyboard focus, and carry a dot while their Module is running.
struct PageSwitcher: View {
    let pages: [SurfacePage]
    let selected: SurfacePage?
    var running: Set<SurfacePage> = []
    var showsButtons = false
    @ObservedObject var pointer: SurfacePointer
    let select: (SurfacePage) -> Void

    /// How much taller the row stands with buttons than with dots.
    static let growth: CGFloat = 14

    /// The dots becoming buttons and back, and the surface letting itself
    /// down to hold them: one spring for both, so they move as one.
    static func motion(reduced: Bool) -> Animation {
        reduced ? .easeInOut(duration: 0.18) : .spring(response: 0.38, dampingFraction: 0.86)
    }

    var body: some View {
        if let selected, pages.count > 1 {
            HStack(spacing: 4) {
                ForEach(pages, id: \.self) { page in
                    PageIndicator(
                        page: page,
                        isCurrent: page == selected,
                        isRunning: running.contains(page),
                        isButton: showsButtons,
                        pointer: pointer
                    ) { select(page) }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: showsButtons ? 8 + Self.growth : 8, alignment: .top)
            .padding(.top, 4)
            .padding(.bottom, 8)
        } else {
            // One page, nothing to switch to: the row keeps the dots' height.
            Color.clear.frame(height: 8).padding(.top, 4).padding(.bottom, 8)
        }
    }
}

/// One page: a dot that becomes a button. It is the same view throughout,
/// so SwiftUI grows it rather than swapping one thing for another.
private struct PageIndicator: View {
    let page: SurfacePage
    let isCurrent: Bool
    let isRunning: Bool
    let isButton: Bool
    @ObservedObject var pointer: SurfacePointer
    let action: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        PointerInside(pointer: pointer) { hovered in
            let lit = isButton && hovered
            Button(action: action) {
                RoundedRectangle(cornerRadius: isButton ? 4 : 3, style: .continuous)
                    .fill(fill(lit: lit))
                    .frame(width: isButton ? 22 : 6, height: isButton ? 22 : 6)
                    // The icon rides on the square and never sizes it.
                    .overlay {
                        SettingsIconView(page.icon)
                            .foregroundStyle(isCurrent || lit ? Color.white : Color(white: 0x97 / 255))
                            .scaleEffect(isButton ? 0.75 : 0.25)
                            .opacity(isButton ? 1 : 0)
                    }
                // The dot's slot is wider than the dot, as the dots were drawn.
                .frame(width: isButton ? 22 : 8, height: isButton ? 22 : 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(PageButtonStyle())
            .allowsHitTesting(isButton)
            .overlay(alignment: .topTrailing) {
                if isRunning && isButton {
                    Circle().fill(SurfaceType.red)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().strokeBorder(Color.black, lineWidth: 1.5).padding(-1.5))
                        .offset(x: 2, y: -2)
                        .transition(.opacity)
                }
            }
            .overlay {
                if focused && isButton {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(SettingsPalette.accent, lineWidth: 2)
                        .padding(-3)
                }
            }
            .overlay(alignment: .top) {
                if lit {
                    Text(page.name)
                        .font(SurfaceType.geist(11, .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .frame(height: 19)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(white: 0x2C / 255)))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                        .fixedSize()
                        .offset(y: -27)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: lit)
            // Reached with the keyboard, never taken by a click — a ring left
            // round the button that was just clicked looked like a fault.
            .focusable(isButton, interactions: .activate)
            .focusEffectDisabled()
            .focused($focused)
            .accessibilityLabel(page.name)
            .accessibilityAddTraits(isCurrent ? .isSelected : [])
        }
    }

    /// As drawn: a dot is bright for the page shown and faint for the rest;
    /// a button is a quiet square, brighter for the page shown and between
    /// the two under the pointer.
    private func fill(lit: Bool) -> Color {
        guard isButton else { return Color.white.opacity(isCurrent ? 0xB3 / 255 : 0x3D / 255) }
        return Color.white.opacity(isCurrent ? 0x66 / 255 : lit ? 0x4D / 255 : 0x2E / 255)
    }
}

private struct PageButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .brightness(configuration.isPressed ? -0.05 : 0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

extension SurfacePage {
    var name: String {
        switch self {
        case .capacity: L("Capacity")
        case .music: L("Music")
        case .teleprompter: L("Teleprompter")
        case .shelf: L("Shelf")
        }
    }

    var icon: SettingsIcon {
        switch self {
        case .capacity: .providers
        case .music: .music
        case .teleprompter: .teleprompter
        case .shelf: .shelf
        }
    }
}
