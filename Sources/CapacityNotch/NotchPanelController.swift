import AppKit
import CapacityNotchCore
import Combine
import CoreGraphics
import os
import SwiftUI

@MainActor
final class NotchPanelController: NSWindowController, NSWindowDelegate {
    private let store: CapacityNotchStore
    private let music: MusicReader
    private let teleprompter: TeleprompterController
    private let shelf: ShelfController
    private let pages = SurfacePages()
    private let pointer = SurfacePointer()
    private var scrollMonitor: Any?
    private var keyMonitor: Any?
    private var swipe: CGFloat = 0
    private let connect: (Provider) -> Void
    private let refresh: (Provider) -> Void
    private let metrics = SurfaceMetrics()
    private let shape = SurfaceShape()
    private var observers: Set<AnyCancellable> = []
    private var pointerTimer: Timer?
    private var presentTicks = 0
    /// The pointer is approaching the closed surface, which rises to meet it.
    private var pointerNear = false
    private var absentTicks = 0
    /// The drag pasteboard as it stood while no button was held, so a drag
    /// that starts is told from one that ended long ago.
    private var dragCountAtRest = NSPasteboard(name: .drag).changeCount
    /// When the button was let go over the drop tab, before the drop arrived.
    private var dragReleasedAt: Date?

    private static let pointerInterval: TimeInterval = 0.1
    /// A pointer passing over the strip on its way somewhere else has not
    /// asked for anything. It must settle for this long before the surface
    /// opens.
    private static let presentTicksBeforeOpen = 3
    /// And a pointer that leaves for an instant has not left.
    private static let absentTicksBeforeClose = 2

    init(
        store: CapacityNotchStore,
        music: MusicReader,
        teleprompter: TeleprompterController,
        shelf: ShelfController,
        connect: @escaping (Provider) -> Void,
        refresh: @escaping (Provider) -> Void
    ) {
        self.store = store
        self.music = music
        self.teleprompter = teleprompter
        self.shelf = shelf
        self.connect = connect
        self.refresh = refresh

        let panel = Self.makePanel()
        let root = NotchRootView(
            store: store,
            metrics: metrics,
            music: music,
            teleprompter: teleprompter,
            shelf: shelf,
            pages: pages,
            shape: shape,
            pointer: pointer,
            connect: connect,
            refresh: refresh
        )
        let host = SurfaceHostingView(rootView: FollowsLanguage { root })
        // The panel alone decides the window's size. As the window's content
        // view, a hosting view resizes the window itself to follow a SwiftUI
        // animation (`updateAnimatedWindowSize`) — with the shape on a spring
        // and the panel setting the frame too, the two fought until AppKit
        // gave up on the constraint pass and ended the application. Inside a
        // plain container it only fills what it is given.
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        let container = SurfaceDropView()
        container.addSubview(host)
        panel.contentView = container
        host.frame = container.bounds

        super.init(window: panel)

        // Files held over the surface: over the closed strip, or its drop tab
        // once it shows, or anywhere on the open surface.
        container.accepts = { [weak self] point in
            guard let self, self.shelf.isEnabled, let panel = self.window else { return false }
            // The tab counts whether or not it is still drawn: the drop comes
            // after the button is let go, and the tab may be folding by then.
            return self.surfaceRegionContains(panel.convertPoint(toScreen: point), withTab: true)
        }
        container.targeted = { [weak self] targeted in
            guard let self, self.shelf.isDropTargeted != targeted else { return }
            self.shelf.isDropTargeted = targeted
        }
        container.drop = { [weak self] urls in
            guard let self else { return }
            self.shelf.add(urls)
            if self.store.presentation == .expanded { self.pages.select(.shelf) }
        }
        container.dropImage = { [weak self] name, data in
            guard let self else { return }
            self.shelf.addInMemory(named: name, data: data)
            if self.store.presentation == .expanded { self.pages.select(.shelf) }
        }

        panel.delegate = self
        panel.dismiss = { [weak self] in self?.store.dismiss() }
        setSharingAllowed(Self.storedSharingAllowed())

        // `@Published` announces a change before it lands, and the panel
        // measures live SwiftUI content. Measuring on that announcement would
        // lay out the layout being left behind at the size of the one
        // arriving. Taking the next turn of the run loop lets the content
        // become what it is about to be before the window is sized to it.
        store.$presentation
            .receive(on: DispatchQueue.main)
            .sink { [weak self] presentation in
                self?.positionPanel(for: presentation, animated: self?.window?.isVisible == true)
            }
            .store(in: &observers)

        // Capacity arriving while the surface is open makes the column taller
        // or shorter. The window has to follow, or it clips what it shows.
        store.$snapshots
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.store.presentation == .expanded else { return }
                self.positionPanel(for: .expanded, animated: true)
            }
            .store(in: &observers)

        // A display arriving, leaving, or changing resolution changes the
        // strip the surface belongs in. Measuring once at launch left it the
        // wrong height on the next screen, and could leave it off-screen
        // altogether.
        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.followDisplays() }
            .store(in: &observers)

        // A track starting or ending grows or shrinks the closed strip by its
        // music row; the window follows so the row is neither clipped nor
        // floating in an empty band.
        music.$shown
            .map { $0 != nil }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.store.presentation == .compact else { return }
                self.positionPanel(for: .compact, animated: self.window?.isVisible == true)
            }
            .store(in: &observers)

        // The Teleprompter Row coming or going, or changing its text size,
        // resizes the closed surface; while it shows, the surface is kept out
        // of screen capture whatever the switch says.
        Publishers.CombineLatest3(
            teleprompter.$playback.map(\.isShowing).removeDuplicates(),
            teleprompter.$textSize.removeDuplicates(),
            teleprompter.$isEnabled.removeDuplicates()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            guard let self else { return }
            self.applySharing()
            guard self.store.presentation == .compact else { return }
            self.positionPanel(for: .compact, animated: self.window?.isVisible == true)
        }
        .store(in: &observers)

        // Which pages there are: a track loading or going, the Teleprompter
        // or the Shelf switched on or off.
        Publishers.CombineLatest3(
            music.$loaded.map { $0 != nil }.removeDuplicates(),
            teleprompter.$isEnabled.removeDuplicates(),
            shelf.$isEnabled.removeDuplicates()
        )
        .sink { [weak self] loaded, teleprompter, shelf in
            self?.pages.setAvailable(SurfacePageOrder.pages(musicLoaded: loaded, teleprompter: teleprompter, shelf: shelf))
        }
        .store(in: &observers)

        // A file held over the closed strip grows the drop tab under it.
        shelf.$isDropTargeted
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.store.presentation == .compact else { return }
                self.positionPanel(for: .compact, animated: true)
            }
            .store(in: &observers)

        // Open, the page shown decides the height, and a page arriving or
        // going changes the dots.
        Publishers.CombineLatest(pages.$available, pages.$selected)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.store.presentation == .expanded else { return }
                self.positionPanel(for: .expanded, animated: true)
            }
            .store(in: &observers)

        watchPageGestures()

        // macOS hides the surface as a Space starts to slide, and tells the
        // Space has changed only once the slide is over (measured on macOS
        // 27.0): asked then, the music row folds away just as the surface
        // comes back, in plain sight. Hidden is the first sign, so the
        // question is asked from there, while nobody can see the answer.
        NotificationCenter.default
            .publisher(for: NSWindow.didChangeOcclusionStateNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self, let panel = self.window, note.object as? NSWindow === panel,
                      !panel.occlusionState.contains(.visible) else { return }
                self.metrics.checkFullscreenAsItSettles()
            }
            .store(in: &observers)

        metrics.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.positionPanel(for: self.store.presentation, animated: false)
            }
            .store(in: &observers)

        // Every Provider switched off: open, and it stays so until one is on.
        store.$snapshots
            .map(SurfaceCards.nothingConnected)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] nothing in if nothing { self?.store.expand() } }
            .store(in: &observers)

        // A pinned surface has to be able to hear Escape and notice a click
        // elsewhere, and a borderless panel hears neither until it is key.
        store.$isPinned
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pinned in
                guard let self, self.window?.isVisible == true else { return }
                if pinned { self.takeKey() } else { self.window?.resignKey() }
            }
            .store(in: &observers)

        positionPanel(for: store.presentation, animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Showing and hiding

    func show() {
        positionPanel(for: store.presentation, animated: false)
        window?.orderFrontRegardless()
        startPointerTracking()
        dumpMetricsIfAsked()
    }

    /// Prints what the surface actually measures, so its size can be compared
    /// with the drawing without anyone squinting at a screenshot.
    private func dumpMetricsIfAsked() {
        guard ProcessInfo.processInfo.environment["CAPACITY_NOTCH_DUMP_METRICS"] == "1" else {
            return
        }

        let width = metrics.geometry.surfaceWidth()

        func height(of view: NSView) -> CGFloat {
            view.frame = NSRect(x: 0, y: 0, width: width, height: 0)
            view.layoutSubtreeIfNeeded()
            return view.fittingSize.height
        }

        let column = height(of: NSHostingView(
            rootView: SurfaceColumn(
                snapshots: store.snapshots,
                geometry: metrics.geometry,
                now: Date(),
                isExpanded: true,
                connect: { _ in },
                refresh: { _ in },
                toggle: {}
            )
        ))
        let detail = height(of: NSHostingView(
            rootView: DetailCapacityView(
                snapshots: store.snapshots,
                now: Date(),
                connect: { _ in },
                refresh: { _ in }
            )
        ))

        let sample = CapacitySnapshot(
            provider: .codex,
            capturedAt: Date(),
            windows: [
                QuotaWindow(id: "a", label: "5 hour", durationMinutes: 300,
                            usedFraction: 0.96, resetsAt: Date().addingTimeInterval(2160)),
                QuotaWindow(id: "b", label: "Weekly", durationMinutes: 10_080,
                            usedFraction: 0.31, resetsAt: Date().addingTimeInterval(187_200)),
            ],
            connectionState: .fresh
        )
        let card = NSHostingView(
            rootView: ProviderCard(snapshot: sample, now: Date(), connect: {}, refresh: {})
        )
        card.frame = NSRect(x: 0, y: 0, width: 256, height: 0)
        card.layoutSubtreeIfNeeded()

        FileHandle.standardError.write(Data(
            "metrics: strip=\(metrics.geometry.menuBarHeight) card=\(card.fittingSize.height) detail=\(detail) column=\(column) width=\(width)\n".utf8
        ))

        // The Music Module, measured against the drawing: the row under the
        // closed strip, the expanded page, and the open surface showing it.
        let track = NowPlaying(
            title: "Mad Technology", artist: "CZARFACE, Frankie Pulitzer, Method Man",
            player: "com.google.Chrome", isPlaying: true, duration: 224, elapsed: 46,
            elapsedAt: Date(), rate: 1
        )
        let row = NSHostingView(
            rootView: CompactMusicRow(track: track, width: metrics.geometry.compactWidth(), send: { _ in })
        )
        let page = height(of: NSHostingView(rootView: MusicPage(track: track, now: Date(), send: { _ in })))
        let playingColumn = height(of: NSHostingView(
            rootView: SurfaceColumn(
                snapshots: store.snapshots,
                geometry: metrics.geometry,
                now: Date(),
                isExpanded: true,
                loaded: track,
                page: .music,
                connect: { _ in },
                refresh: { _ in },
                toggle: {}
            )
        ))
        FileHandle.standardError.write(Data(
            "music: row=\(row.fittingSize.height) page=\(page) open=\(playingColumn) closed=\(metrics.geometry.menuBarHeight + row.fittingSize.height)\n".utf8
        ))

        // Pictures of both, to hold against the drawing, when asked for.
        if let folder = ProcessInfo.processInfo.environment["CAPACITY_NOTCH_DUMP_PICTURES"] {
            func picture(_ view: some View, width: CGFloat, named name: String) {
                let host = NSHostingView(rootView: view.background(Color.black))
                host.frame = NSRect(x: 0, y: 0, width: width, height: 0)
                host.layoutSubtreeIfNeeded()
                host.frame.size = host.fittingSize
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: folder).appendingPathComponent(name))
            }
            let geometry = metrics.geometry
            // The shape itself, shoulders and all, over a menu bar, at both
            // scalings a MacBook Pro draws its notch at.
            for (name, notch, bar) in [("shape-default", CGFloat(185), CGFloat(32)), ("shape-more-space", 220, 38)] {
                let drawn = NotchGeometry(menuBarHeight: bar, notchWidth: notch)
                let full = [sample, CapacitySnapshot(provider: .claudeCode, capturedAt: Date(), windows: sample.windows, connectionState: .fresh)]
                for (state, expanded) in [("compact", false), ("expanded", true)] {
                    let width = expanded ? drawn.surfaceWidth() : drawn.compactWidth()
                    let height = expanded ? CGFloat(252 - 38) + bar : bar
                    let outline = NotchOutline(size: CGSize(width: width, height: height), radius: expanded ? 38 : 22)
                    picture(
                        ZStack(alignment: .top) {
                            Color(white: 0.63)
                            Rectangle().fill(Color(white: 0.56)).frame(height: bar)
                            outline.fill(Color.black)
                            SurfaceColumn(snapshots: full, geometry: drawn, now: Date(), isExpanded: expanded,
                                          connect: { _ in }, refresh: { _ in }, toggle: {})
                                .frame(width: drawn.surfaceWidth(), height: height, alignment: .top)
                                .clipShape(outline)
                        }
                        .frame(width: drawn.surfaceWidth() + 60, height: height + 30),
                        width: drawn.surfaceWidth() + 60, named: "\(name)-\(state).png"
                    )
                }
            }
            // A card with windows in it, which a fresh launch has not read yet.
            picture(ProviderCard(snapshot: sample, now: Date(), connect: {}, refresh: {}), width: 256, named: "card.png")
            drawShelf(into: folder, sample: [sample, CapacitySnapshot(provider: .claudeCode, capturedAt: Date(), windows: sample.windows, connectionState: .fresh)])
            // One Provider on, the other off: "Notch — Compact/Expanded — One provider".
            let one = [
                UnreadCapacity.snapshot(for: .codex),
                CapacitySnapshot(provider: .claudeCode, capturedAt: Date(), windows: sample.windows, connectionState: .fresh),
            ]
            picture(
                SurfaceColumn(snapshots: one, geometry: geometry, now: Date(), isExpanded: false,
                              connect: { _ in }, refresh: { _ in }, toggle: {})
                    .frame(height: geometry.menuBarHeight, alignment: .top).clipped(),
                width: geometry.surfaceWidth(), named: "compact-one-provider.png"
            )
            picture(
                SurfaceColumn(snapshots: one, geometry: geometry, now: Date(), isExpanded: true,
                              connect: { _ in }, refresh: { _ in }, toggle: {}),
                width: geometry.surfaceWidth(), named: "expanded-one-provider.png"
            )
            picture(
                SurfaceColumn(snapshots: [sample, one[1]], geometry: geometry, now: Date(), isExpanded: false,
                              connect: { _ in }, refresh: { _ in }, toggle: {})
                    .frame(height: geometry.menuBarHeight, alignment: .top).clipped(),
                width: geometry.surfaceWidth(), named: "compact-two-providers.png"
            )
            picture(
                VStack(spacing: 0) {
                    SurfaceColumn(
                        snapshots: store.snapshots, geometry: geometry, now: Date(),
                        isExpanded: false, playing: track, connect: { _ in }, refresh: { _ in }, toggle: {}
                    )
                    .frame(height: geometry.menuBarHeight + MusicType.rowHeight, alignment: .top)
                    .clipped()
                },
                width: geometry.surfaceWidth(), named: "compact-playing.png"
            )
            picture(
                SurfaceColumn(
                    snapshots: store.snapshots, geometry: geometry, now: Date(),
                    isExpanded: true, loaded: track, page: .music,
                    connect: { _ in }, refresh: { _ in }, toggle: {}
                ),
                width: geometry.surfaceWidth(), named: "expanded-playing.png"
            )
            picture(
                SurfaceColumn(
                    snapshots: store.snapshots, geometry: geometry, now: Date(),
                    isExpanded: true, loaded: track, page: .capacity,
                    connect: { _ in }, refresh: { _ in }, toggle: {}
                ),
                width: geometry.surfaceWidth(), named: "expanded.png"
            )
            picture(
                SurfaceColumn(
                    snapshots: UnreadCapacity.snapshots(), geometry: geometry, now: Date(),
                    isExpanded: true, loaded: track, page: .capacity,
                    connect: { _ in }, refresh: { _ in }, toggle: {}
                ),
                width: geometry.surfaceWidth(), named: "disconnected.png"
            )
            picture(
                SurfaceColumn(
                    snapshots: store.snapshots, geometry: geometry, now: Date(),
                    isExpanded: false, connect: { _ in }, refresh: { _ in }, toggle: {}
                )
                .frame(height: geometry.menuBarHeight, alignment: .top)
                .clipped(),
                width: geometry.surfaceWidth(), named: "compact.png"
            )
        }
    }

    /// The Teleprompter's closed row and open page, drawn from `standIn` into
    /// `folder`, with their heights. The row is Core Animation, so it is
    /// rendered from the layer tree rather than drawn.
    /// The Shelf against Paper "Notch — … — Shelf", "— Shelf empty",
    /// "— Dropping on the Shelf" and "Notch — Page switcher — States", from a
    /// stand-in holding sample files made for the purpose — never the
    /// person's own Shelf.
    private func drawShelf(into folder: String, sample: [CapacitySnapshot]) {
        let suite = "capacity-notch-shelf-dump-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let demo = Preferences(defaults: defaults)
        let standIn = ShelfController(preferences: demo)
        standIn.setEnabled(true)
        let geometry = metrics.geometry
        let width = geometry.surfaceWidth()

        func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.3)) }
        func picture(_ view: some View, height: CGFloat? = nil, named name: String) {
            let host = NSHostingView(rootView: view.coordinateSpace(name: SurfacePointer.space).background(Color.black))
            host.frame = NSRect(x: 0, y: 0, width: width, height: 0)
            host.layoutSubtreeIfNeeded()
            host.frame.size = height.map { NSSize(width: width, height: $0) } ?? host.fittingSize
            // Hover reads frames measured on the way in; one more turn lets them land.
            settle()
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent(name))
        }
        func column(pointer: SurfacePointer = SurfacePointer(), dropping: Bool = false, expanded: Bool = true, buttons: Bool = false) -> some View {
            SurfaceColumn(
                snapshots: sample, geometry: geometry, now: Date(), isExpanded: expanded,
                teleprompter: teleprompter, shelf: standIn, pointer: pointer, dropping: dropping,
                page: .shelf, controlsShown: buttons, connect: { _ in }, refresh: { _ in }, toggle: {}
            )
        }

        picture(column(), named: "shelf-empty.png")

        let files = FileManager.default.temporaryDirectory.appendingPathComponent("capacity-notch-shelf-sample")
        try? FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let names = ["Договор.docx", "Демо для команды.key", "CapacityNotch-0.2.8.zip", "Снимок экрана 12.41.png", "Отчёт за сентябрь.pdf"]
        for name in names {
            let url = files.appendingPathComponent(name)
            if name.hasSuffix(".png") {
                let image = NSImage(size: NSSize(width: 112, height: 76), flipped: false) { rect in
                    NSGradient(colors: [NSColor(red: 0.17, green: 0.24, blue: 0.34, alpha: 1), NSColor(red: 0.56, green: 0.69, blue: 0.8, alpha: 1)])?
                        .draw(in: rect, angle: 45)
                    return true
                }
                if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: url)
                }
            } else {
                try? Data("sample".utf8).write(to: url)
            }
        }
        standIn.add(names.map { files.appendingPathComponent($0) })
        // One file moved away since it was set down.
        try? FileManager.default.removeItem(at: files.appendingPathComponent("Договор.docx"))
        standIn.refreshAvailability()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))

        picture(column(), named: "shelf.png")
        // The pointer on the first tile, then over the switcher.
        let onTile = SurfacePointer()
        onTile.location = CGPoint(x: 60, y: 38 + 60)
        picture(column(pointer: onTile), named: "shelf-hover-tile.png")
        let tall = NSHostingView(rootView: column())
        tall.frame = NSRect(x: 0, y: 0, width: width, height: 0)
        tall.layoutSubtreeIfNeeded()
        let bottom = tall.fittingSize.height
        let near = SurfacePointer()
        near.location = CGPoint(x: width / 2 - 90, y: bottom - 14)
        picture(column(pointer: near, buttons: true), named: "switcher-near.png")
        let onButton = SurfacePointer()
        // The first of the buttons, which stand 14 points lower than the dots.
        onButton.location = CGPoint(x: width / 2 - 13, y: bottom + PageSwitcher.growth - 19)
        picture(column(pointer: onButton, buttons: true), named: "switcher-hover.png")

        // Closed, with a file held over it: the strip and its drop tab.
        let tab = ShelfDropZone.tab
        // At its give, as the strip is while a file is held near it.
        let strip = CGSize(width: geometry.compactWidth() + Self.nearGrowth.width, height: geometry.menuBarHeight + Self.nearGrowth.height)
        let outline = NotchOutline(size: strip, radius: 22, tab: tab)
        picture(
            ZStack(alignment: .top) {
                Color(white: 0.16)
                outline.fill(Color.black)
                column(dropping: true, expanded: false)
                    .frame(width: width, height: strip.height + tab.height, alignment: .top)
                    .clipShape(outline)
            },
            height: strip.height + tab.height + 20,
            named: "shelf-dropping.png"
        )
        try? FileManager.default.removeItem(at: files)
    }

    func drawTeleprompter(_ standIn: TeleprompterController, to folder: String) {
        let geometry = metrics.geometry
        ScriptScrollView.drawnForPictures = true
        defer { ScriptScrollView.drawnForPictures = false }
        func picture(_ view: some View, named name: String) -> CGFloat {
            let host = NSHostingView(rootView: view.background(Color.black))
            host.frame = NSRect(x: 0, y: 0, width: geometry.surfaceWidth(), height: 0)
            host.layoutSubtreeIfNeeded()
            host.frame.size = host.fittingSize
            // Out of a window a hosted AppKit view's layer hangs from nothing,
            // and the render cannot reach it.
            // Inside a plain container, never as the content view (see init).
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            let container = NSView(frame: host.frame)
            container.addSubview(host)
            window.contentView = container
            host.layoutSubtreeIfNeeded()
            host.layer?.displayIfNeeded()
            let scale: CGFloat = 2
            let size = host.bounds.size
            guard let context = CGContext(
                data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return size.height }
            // Layers draw with the origin at the top; the context has it at
            // the bottom.
            context.translateBy(x: 0, y: size.height * scale)
            context.scaleBy(x: scale, y: -scale)
            host.layer?.render(in: context)
            // SwiftUI keeps a hosted AppKit view's layer out of its own tree,
            // so the Script's lines are drawn on top, where the row stands.
            func scrolls(in view: NSView) -> [ScriptScrollView] {
                (view as? ScriptScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls)
            }
            func shown(_ view: NSView?) -> Bool {
                guard let view else { return true }
                return !view.isHidden && view.alphaValue > 0 && shown(view.superview)
            }
            for scroll in scrolls(in: host) where shown(scroll) {
                let frame = scroll.convert(scroll.bounds, to: host)
                context.saveGState()
                context.translateBy(x: frame.minX, y: frame.minY)
                scroll.layer?.render(in: context)
                context.restoreGState()
            }
            if let image = context.makeImage() {
                let rep = NSBitmapImageRep(cgImage: image)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: folder).appendingPathComponent(name))
            }
            return size.height
        }
        let closed = picture(
            SurfaceColumn(
                snapshots: store.snapshots, geometry: geometry, now: Date(),
                isExpanded: false, teleprompter: standIn, connect: { _ in }, refresh: { _ in }, toggle: {}
            )
            .frame(height: geometry.menuBarHeight + TeleprompterLayout.rowHeight(standIn.textSize), alignment: .top)
            .clipped(),
            named: "compact-teleprompter.png"
        )
        let open = picture(
            SurfaceColumn(
                snapshots: store.snapshots, geometry: geometry, now: Date(),
                isExpanded: true, teleprompter: standIn, page: .teleprompter,
                connect: { _ in }, refresh: { _ in }, toggle: {}
            ),
            named: "expanded-teleprompter.png"
        )
        FileHandle.standardError.write(Data(
            "teleprompter: row=\(TeleprompterLayout.rowHeight(standIn.textSize)) closed=\(closed) open=\(open) lines=\(standIn.lines.count) words=\(standIn.wordCount)\n".utf8
        ))
    }

    /// Opens the surface, as finishing onboarding does: the first thing the
    /// person should see is the Capacity they just connected.
    func open() {
        store.pin()
    }

    // MARK: - Screen sharing

    /// Whether the surface appears in screen recordings and shared screens.
    ///
    /// Off by default: Capacity is the person's account standing, and a shared
    /// screen is the easiest way to show it to a room by accident. macOS can
    /// exclude a window from the capture paths it controls; it cannot promise
    /// anything about a camera pointed at the screen, so this is a strong
    /// default rather than a guarantee.
    private(set) var sharingAllowed = false

    func setSharingAllowed(_ allowed: Bool) {
        sharingAllowed = allowed
        UserDefaults.standard.set(allowed, forKey: "allowScreenSharing")
        applySharing()
    }

    private func applySharing() {
        let excluded = TeleprompterSurface.excludedFromCapture(
            sharingAllowed: sharingAllowed,
            teleprompterShowing: teleprompter.isShowingRow
        )
        let type: NSWindow.SharingType = excluded ? .none : .readOnly
        // On macOS 27 a window kept out of capture never comes back: setting
        // it shared again reads back as excluded. The surface is shared again
        // by moving its content into a new panel.
        if type == .readOnly, let old = window as? NotchPanel, old.sharingType == .none {
            replacePanel(old)
        }
        window?.sharingType = type
        sharingTypeChanged?(type)
    }

    private func replacePanel(_ old: NotchPanel) {
        let fresh = Self.makePanel()
        let content = old.contentView
        let visible = old.isVisible, key = old.isKeyWindow
        old.contentView = NSView()
        old.delegate = nil
        old.orderOut(nil)
        fresh.contentView = content
        fresh.setFrame(old.frame, display: false)
        fresh.delegate = self
        fresh.dismiss = old.dismiss
        window = fresh
        if key { fresh.makeKeyAndOrderFront(nil) } else if visible { fresh.orderFrontRegardless() }
    }

    private static func makePanel() -> NotchPanel {
        let panel = NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // No shadow. A surface that continues the menu bar has nothing to
        // cast one onto, and AppKit builds a borderless panel's shadow from
        // the window rectangle rather than from the rounded shape clipped
        // inside it — which drew a pale rim along the edges where the two
        // disagreed.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        // One surface, on every Space and over a fullscreen application, and
        // never a second copy on another display.
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        return panel
    }

    private static func storedSharingAllowed() -> Bool {
        UserDefaults.standard.bool(forKey: "allowScreenSharing")
    }

    // MARK: - Displays

    var displays: [DisplayDescriptor] { metrics.displays }
    var chosenDisplay: DisplayDescriptor? { metrics.chosenDisplay }

    func useDisplay(_ id: UInt32?) {
        metrics.preferredDisplayID = id
    }

    private func followDisplays() {
        metrics.refresh()
        positionPanel(for: store.presentation, animated: false)
    }

    // MARK: - The pointer

    /// The panel lives as long as the application, so its watches are released
    /// here rather than in a deinitialiser that cannot reach them.
    func stopPointerTracking() {
        pointerTimer?.invalidate()
        pointerTimer = nil
        pointerNear = false
        presentTicks = 0
        absentTicks = 0
    }

    /// The surface watches where the pointer is, rather than waiting to be
    /// told that it arrived.
    ///
    /// Neither kind of event monitor can see this panel's pointer. A global
    /// monitor skips events aimed at its own application, and a local monitor
    /// never receives mouse movement while this panel is not the key window.
    /// Asking for the pointer's position answers both, and it cannot be
    /// confused by a window that resizes underneath the pointer.
    private func startPointerTracking() {
        guard pointerTimer == nil else { return }

        let timer = Timer(timeInterval: Self.pointerInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.readPointer() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
    }

    private func readPointer() {
        guard let panel = window, panel.isVisible else { return }

        // The window is larger than the surface, and around the shape it is
        // transparent. It lets the pointer through there, to the menu bar and
        // whatever lies under it, and takes it only over the shape itself.
        let top = panel.frame.maxY
        let surface = NSRect(
            x: panel.frame.midX - shape.size.width / 2,
            y: top - shape.size.height,
            width: shape.size.width,
            height: shape.size.height
        )
        let mouse = NSEvent.mouseLocation
        let overSurface = surfaceRegionContains(mouse, withTab: shelf.isDropTargeted)
        if panel.ignoresMouseEvents == overSurface { panel.ignoresMouseEvents = !overSurface }

        followPageSwitcher(surface: surface, mouse: mouse)

        // What lights under the pointer on the open surface reads it here.
        let location: CGPoint? = store.presentation == .expanded && overSurface
            ? CGPoint(x: mouse.x - panel.frame.minX, y: panel.frame.maxY - mouse.y)
            : nil
        if location != pointer.location { pointer.location = location }

        // Closed, the surface answers to its strip — and only the strip, so
        // a music row under it keeps its buttons within reach; open, to the
        // whole of itself. The region is the shape's, not the window's.
        let region = store.presentation == .expanded
            ? surface
            : NSRect(
                x: panel.frame.midX - metrics.geometry.compactWidth() / 2,
                y: top - metrics.geometry.menuBarHeight,
                width: metrics.geometry.compactWidth(),
                height: metrics.geometry.menuBarHeight
            )
        // A file carried towards the closed strip grows the drop tab while
        // the pointer is still near — as the strip would give a little —
        // not once it is over the strip: carried any higher, macOS takes the
        // top edge for its own Spaces bar before the drop can happen.
        followFileDrag(near: region, mouse: mouse)

        // Closed, the surface grows a little as the pointer comes near it,
        // before it is over it and long before it opens.
        let near = store.presentation == .compact
            && region.insetBy(dx: -Self.nearDistance, dy: -Self.nearDistance).contains(NSEvent.mouseLocation)
        if near != pointerNear {
            pointerNear = near
            positionPanel(for: store.presentation, animated: true, nearing: true)
        }

        guard !region.contains(NSEvent.mouseLocation) else {
            absentTicks = 0
            // A button held down is a drag on its way somewhere — a file for
            // the Shelf among them — not a pointer resting on the strip.
            guard NSEvent.pressedMouseButtons & 1 == 0, !shelf.isDropTargeted else {
                presentTicks = 0
                return
            }
            // While the Script runs, a passing pointer does not open the
            // surface over it; a click on the strip still does.
            guard TeleprompterSurface.hoverOpens(teleprompter: teleprompter.playback.state) else {
                presentTicks = 0
                return
            }
            presentTicks += 1
            if presentTicks >= Self.presentTicksBeforeOpen { store.expand() }
            return
        }

        presentTicks = 0

        // A pinned surface was asked for. It waits to be dismissed. With no
        // Provider on it stays open, on the cards that connect one.
        guard store.presentation == .expanded, !store.isPinned, !SurfaceCards.nothingConnected(store.snapshots) else {
            absentTicks = 0
            return
        }

        absentTicks += 1
        guard absentTicks >= Self.absentTicksBeforeClose else { return }

        absentTicks = 0
        store.collapse()
    }

    /// A click anywhere else dismisses a pinned surface.
    func windowDidResignKey(_ notification: Notification) {
        guard store.isPinned else { return }
        store.dismiss()
    }

    /// Called when the surface is pinned, so Escape and a click elsewhere can
    /// reach it. A borderless panel receives neither while it is not key.
    func takeKey() {
        window?.makeKeyAndOrderFront(nil)
    }

    /// Open, the page dots become buttons as the pointer comes down to them,
    /// and the surface lets itself down to hold them; they go back to dots
    /// once it has moved well away, so the edge of the reach does not flicker.
    private func followPageSwitcher(surface: NSRect, mouse: NSPoint) {
        let shown: Bool
        if store.presentation == .expanded, pages.available.count > 1,
           mouse.x >= surface.minX, mouse.x <= surface.maxX, mouse.y >= surface.minY {
            let fromBottom = mouse.y - surface.minY
            shown = pages.controlsShown ? fromBottom < Self.switcherLeaves : fromBottom < Self.switcherReach
        } else {
            shown = false
        }
        guard shown != pages.controlsShown else { return }
        let motion = PageSwitcher.motion(reduced: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        withAnimation(motion) {
            pages.controlsShown = shown
        }
        // The surface lets itself down on the same spring, measured with the
        // buttons already there.
        positionPanel(for: .expanded, animated: true, motion: motion)
    }

    /// How close to the open surface's bottom edge the pointer comes before
    /// the dots become buttons, and how far it goes before they are dots again.
    private static let switcherReach: CGFloat = 40
    private static let switcherLeaves: CGFloat = 58

    /// Whether a file is being dragged right now, anywhere: a button held,
    /// and the drag pasteboard changed since it was pressed and carrying
    /// files. Only its types are read, never what it holds.
    private var fileDragUnderWay: Bool {
        let board = NSPasteboard(name: .drag)
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            dragCountAtRest = board.changeCount
            return false
        }
        return board.changeCount != dragCountAtRest && SurfaceDropView.carriesFiles(board.types ?? [])
    }

    /// Opens the drop tab while a file is carried near the closed strip, and
    /// keeps it open while the pointer is over the tab it opened.
    private func followFileDrag(near strip: NSRect, mouse: NSPoint) {
        guard shelf.isEnabled, store.presentation == .compact, fileDragUnderWay else {
            // Let go, the drop is delivered a moment later; the tab stays
            // until then, or the drop lands on a tab that is no longer there.
            // The drop view closes it when the drag ends; this is the fallback.
            if shelf.isDropTargeted {
                if dragReleasedAt == nil { dragReleasedAt = Date() }
                if let released = dragReleasedAt, Date().timeIntervalSince(released) > 0.6 {
                    shelf.isDropTargeted = false
                    dragReleasedAt = nil
                }
            }
            return
        }
        dragReleasedAt = nil
        let approach = strip.insetBy(dx: -Self.nearDistance, dy: -Self.nearDistance)
        let tab = ShelfDropZone.tab
        let hanging = NSRect(
            x: strip.midX - tab.width / 2 - Self.nearDistance,
            y: strip.minY - tab.height - Self.nearDistance,
            width: tab.width + Self.nearDistance * 2,
            height: tab.height + Self.nearDistance
        )
        let wanted = approach.contains(mouse) || (shelf.isDropTargeted && hanging.contains(mouse))
        if wanted != shelf.isDropTargeted { shelf.isDropTargeted = wanted }
    }

    /// The shape as it stands, in screen coordinates, with the Shelf's drop
    /// tab at its full size when asked — measured at the size it is growing
    /// to, so a pointer moving down into it is not lost while it grows.
    private func surfaceRegionContains(_ point: NSPoint, withTab: Bool) -> Bool {
        guard let panel = window else { return false }
        let top = panel.frame.maxY
        let surface = NSRect(
            x: panel.frame.midX - shape.size.width / 2,
            y: top - shape.size.height,
            width: shape.size.width,
            height: shape.size.height
        )
        if surface.contains(point) { return true }
        guard withTab, store.presentation == .compact else { return false }
        let tab = ShelfDropZone.tab
        return NSRect(
            x: panel.frame.midX - tab.width / 2,
            y: top - shape.size.height - tab.height,
            width: tab.width,
            height: tab.height
        ).contains(point)
    }

    // MARK: - Pages

    /// Moving between the expanded surface's pages: a two-finger swipe, and —
    /// for anyone without a trackpad — the arrow keys while it is pinned.
    /// VoiceOver has its own actions on the column.
    private func watchPageGestures() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            if self.moveScript(with: event) { return nil }
            return self.follow(swipe: event) ? nil : event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, self.canTurnPages else { return event }
            switch event.keyCode {
            case 123: self.pages.previous(); return nil
            case 124: self.pages.next(); return nil
            default: return event
            }
        }
    }

    private var canTurnPages: Bool {
        store.presentation == .expanded && pages.available.count > 1
    }

    /// Two fingers on the Teleprompter Row, closed: the Script follows them,
    /// whichever way the person has scrolling set, and pauses. It stops when
    /// they lift — the glide after is not theirs. Open, two fingers still
    /// turn pages.
    private func moveScript(with event: NSEvent) -> Bool {
        guard store.presentation == .compact,
              teleprompter.isShowingRow,
              event.hasPreciseScrollingDeltas,
              abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX),
              let panel = window
        else { return false }
        guard event.momentumPhase.isEmpty else { return true }
        // Only over the row: under the strip, inside the shape.
        let point = NSEvent.mouseLocation
        let row = NSRect(
            x: panel.frame.midX - shape.size.width / 2,
            y: panel.frame.maxY - shape.size.height,
            width: shape.size.width,
            height: shape.size.height - metrics.geometry.menuBarHeight
        )
        guard row.contains(point) else { return false }
        let followed = event.isDirectionInvertedFromDevice ? event.scrollingDeltaY : -event.scrollingDeltaY
        teleprompter.move(byLines: -Double(followed / TeleprompterLayout.pitch(teleprompter.textSize)))
        return true
    }

    /// Accumulates one horizontal swipe and turns a page when it ends, so one
    /// gesture is one page however long it runs.
    private func follow(swipe event: NSEvent) -> Bool {
        guard canTurnPages, event.hasPreciseScrollingDeltas else { return false }
        guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) || swipe != 0 else { return false }

        // Fingers moving left bring the next page in, as on a phone,
        // whichever way the person has scrolling set.
        let travel = { event.isDirectionInvertedFromDevice ? self.swipe : -self.swipe }

        switch event.phase {
        case .began:
            swipe = 0
            pages.follow(0)
        case .changed:
            swipe += event.scrollingDeltaX
            pages.follow(travel())
        case .ended, .cancelled:
            pages.settle(travel())
            swipe = 0
        default:
            break
        }
        return true
    }

    // MARK: - Placement

    private(set) var surfaceFrame: NSRect = .zero
    var surfaceFrameChanged: ((NSRect) -> Void)?
    /// The Dictation capsule belongs to the surface, so it is shared or kept
    /// out of capture exactly as the surface is.
    var sharingTypeChanged: ((NSWindow.SharingType) -> Void)? {
        didSet { applySharing() }
    }

    /// How close the pointer comes before the closed surface grows, and by
    /// how much ("Screen — 16″ more space — Compact": 410 by 38 to 420 by 42).
    private static let nearDistance: CGFloat = 60
    private static let nearGrowth = CGSize(width: 10, height: 4)

    private func positionPanel(
        for presentation: CapacityNotchStore.Presentation,
        animated: Bool,
        nearing: Bool = false,
        motion override: Animation? = nil
    ) {
        guard let panel = window, let screen = metrics.screen else { return }

        let geometry = metrics.geometry
        let openWidth = geometry.surfaceWidth()
        var size = switch presentation {
        case .compact:
            switch compactRow {
            case .teleprompter:
                NSSize(
                    width: openWidth,
                    height: geometry.menuBarHeight + TeleprompterLayout.rowHeight(teleprompter.textSize)
                )
            case .music:
                NSSize(width: geometry.compactWidth(), height: geometry.menuBarHeight + MusicType.rowHeight)
            case .none:
                NSSize(width: geometry.compactWidth(), height: geometry.menuBarHeight)
            }
        case .expanded:
            NSSize(width: openWidth, height: expandedHeight(on: screen, width: openWidth))
        }
        // A file held over it keeps the strip's give too, the drop tab
        // hanging from it ("Notch — Compact — Dropping on the Shelf").
        if presentation == .compact, pointerNear || shelf.isDropTargeted {
            size.width += Self.nearGrowth.width
            size.height += Self.nearGrowth.height
        }
        let tab = presentation == .compact && shelf.isDropTargeted ? ShelfDropZone.tab : .zero
        surfaceFrame = Self.frame(of: size, on: screen)
        surfaceFrameChanged?(surfaceFrame)
        let radius: CGFloat = presentation == .expanded ? 38 : 22

        // The window keeps one size, and only the black shape inside it
        // moves. A window resized under a SwiftUI animation left the layout
        // a step behind it, and the shape was drawn where the old window had
        // been — above the screen or off to one side. So the window is sized
        // once for the open surface with room for the spring's overshoot,
        // and grows, without animation, only if the content outgrows it.
        let room = NSSize(
            width: max(panel.frame.width, geometry.surfaceWidth() + Self.overshoot * 2),
            height: max(panel.frame.height, size.height + tab.height + Self.overshoot, Self.minimumRoomHeight)
        )
        let frame = Self.frame(of: room, on: screen)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }

        guard animated else {
            shape.size = size
            shape.radius = radius
            shape.tab = tab
            return
        }

        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // Growing towards the pointer is a small, quick give, not an opening.
        let motion = override ?? (nearing
            ? (reduced ? .easeInOut(duration: 0.15) : .spring(response: 0.28, dampingFraction: 0.7))
            : SurfaceType.surfaceMotion(opening: presentation == .expanded, reduced: reduced))
        withAnimation(motion) {
            shape.size = size
            shape.radius = radius
            shape.tab = tab
        }
    }

    /// How far past its size the opening spring may carry the shape.
    private static let overshoot: CGFloat = 24
    /// Enough for the open surface as drawn, with a sentence of guidance in
    /// a card, so the window rarely has to grow at all.
    private static let minimumRoomHeight: CGFloat = 320

    private static func frame(of size: NSSize, on screen: NSScreen) -> NSRect {
        NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// Closed, a track adds its row under the strip — except over a
    /// fullscreen application, where the strip stands alone — and the
    /// Teleprompter Row takes its place while it shows, fullscreen or not.
    private var compactRow: TeleprompterSurface.CompactRow {
        TeleprompterSurface.compactRow(
            teleprompterShowing: teleprompter.isShowingRow,
            musicShown: music.shown != nil,
            fullscreen: metrics.isFullscreen
        )
    }

    /// The expanded surface follows its content and nothing else. A Provider
    /// that is disconnected explains itself in a sentence, and a fixed height
    /// would cut that sentence in half; a floor under it left the music page,
    /// drawn at 185, standing 218 tall over 33 points of nothing.
    private func expandedHeight(on screen: NSScreen, width: CGFloat) -> CGFloat {
        let measuring = NSHostingView(
            rootView: SurfaceColumn(
                snapshots: store.snapshots,
                geometry: metrics.geometry,
                now: Date(),
                isExpanded: true,
                loaded: music.loaded,
                teleprompter: teleprompter,
                shelf: shelf,
                page: pages.selected,
                controlsShown: pages.controlsShown,
                connect: { _ in },
                refresh: { _ in },
                toggle: {}
            )
        )
        measuring.frame = NSRect(x: 0, y: 0, width: width, height: 0)
        measuring.layoutSubtreeIfNeeded()

        return min(measuring.fittingSize.height, screen.visibleFrame.height)
    }
}

/// The surface is never the active window, and AppKit keeps the first click
/// on an inactive window from SwiftUI's tap gestures — the Teleprompter Row's
/// pause among them. Buttons take it anyway; this lets the rest do the same.
private final class SurfaceHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The panel's content: takes files dragged onto the surface for the Shelf.
/// Whether a point counts, and what a drop does, the panel decides.
private final class SurfaceDropView: NSView {
    var accepts: (NSPoint) -> Bool = { _ in false }
    var targeted: (Bool) -> Void = { _ in }
    var drop: ([URL]) -> Void = { _ in }
    /// An image with no file behind it, to hold in memory: its name, its bytes.
    var dropImage: (String, Data) -> Void = { _, _ in }

    /// Files, and files promised: a screenshot's floating thumbnail or an
    /// image from a browser, which are written only where they are dropped.
    private static let promised = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    /// An image with no file behind it — dragged from a browser — is kept
    /// too, written where screenshots go (ADR 0005, amended).
    private static let images: [NSPasteboard.PasteboardType] = [.png, .tiff]

    static func carriesFiles(_ types: [NSPasteboard.PasteboardType]) -> Bool {
        types.contains(.fileURL) || types.contains { promised.contains($0) || images.contains($0) }
    }

    private static let logger = Logger(subsystem: "app.capacitynotch.CapacityNotch", category: "Shelf")

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL] + Self.promised)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // The kinds of thing offered, never what they hold.
        let types = (sender.draggingPasteboard.types ?? []).map(\.rawValue).joined(separator: ", ")
        Self.logger.info("Drag entered with types: \(types, privacy: .public)")
        return follow(sender)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { follow(sender) }
    // Leaving the shape is not leaving the tab's reach: the panel, which
    // follows the pointer, closes it. Only the drag's end does here.
    override func draggingEnded(_ sender: NSDraggingInfo) { targeted(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = Self.files(in: sender)
        let promises = urls.isEmpty ? Self.promises(in: sender) : []
        // Read now, while the pasteboard is still there: a browser that
        // promises a file can cancel writing it, and its image is the fallback.
        let image = urls.isEmpty ? NSImage(pasteboard: sender.draggingPasteboard) : nil
        let counts = (!urls.isEmpty || !promises.isEmpty || image != nil) && accepts(sender.draggingLocation)
        Self.logger.info("Drop: \(urls.count) files, \(promises.count) promises, image \(image != nil), accepted \(counts)")
        targeted(false)
        guard counts else { return false }
        if !urls.isEmpty {
            drop(urls)
            return true
        }
        if promises.isEmpty, let image {
            guard let png = Self.png(image) else { return false }
            dropImage(Self.imageName(), png)
            return true
        }
        // A promise is received into a folder of our own for a moment, taken
        // into memory, and the file removed: the Shelf writes nothing that
        // outlives it (ADR 0005, amended).
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("capacity-notch-shelf-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (index, promise) in promises.enumerated() {
            // The image stands in once, for the first promise, not once each.
            let image = index == 0 ? image : nil
            promise.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: Self.receiving) { [weak self] url, error in
                let data = error == nil ? try? Data(contentsOf: url) : nil
                if error == nil { try? FileManager.default.removeItem(at: url) }
                if let error {
                    Self.logger.error("Promised file not received: \(String(describing: error), privacy: .public)")
                }
                DispatchQueue.main.async {
                    if let data {
                        self?.dropImage(url.lastPathComponent, data)
                    } else if let image, let png = Self.png(image) {
                        // Yandex Browser and others cancel the promise at
                        // times; the image they sent alongside it is kept.
                        self?.dropImage(Self.imageName(), png)
                    }
                    try? FileManager.default.removeItem(at: folder)
                }
            }
        }
        return true
    }

    private static let receiving: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    private static func png(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }

    /// An image dropped without a name of its own is named by when, as a
    /// screenshot is.
    private static func imageName() -> String {
        let screenshot = ScreenshotClipboard.name(at: Date())
        let stamp = screenshot.drop { !$0.isNumber }
        return L("Image %@", String(stamp))
    }

    private static func promises(in sender: NSDraggingInfo) -> [NSFilePromiseReceiver] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver]) ?? []
    }

    /// Only files, and only over the surface. The Shelf keeps a reference,
    /// so what the source is told is a copy — nothing of its is moved.
    private func follow(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard Self.carriesFiles(sender.draggingPasteboard.types ?? []), accepts(sender.draggingLocation) else { return [] }
        targeted(true)
        return .copy
    }

    private static func files(in sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}

private final class NotchPanel: NSPanel {
    var dismiss: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Escape closes a pinned surface, the way Escape closes anything.
    override func cancelOperation(_ sender: Any?) {
        dismiss?()
    }
}
