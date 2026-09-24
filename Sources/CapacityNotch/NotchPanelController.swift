import AppKit
import CapacityNotchCore
import Combine
import CoreGraphics
import SwiftUI

@MainActor
final class NotchPanelController: NSWindowController, NSWindowDelegate {
    private let store: CapacityNotchStore
    private let music: MusicReader
    private let pages = SurfacePages()
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
    private var absentTicks = 0

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
        connect: @escaping (Provider) -> Void,
        refresh: @escaping (Provider) -> Void
    ) {
        self.store = store
        self.music = music
        self.connect = connect
        self.refresh = refresh

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
        let host = NSHostingView(
            rootView: NotchRootView(
                store: store,
                metrics: metrics,
                music: music,
                pages: pages,
                shape: shape,
                connect: connect,
                refresh: refresh
            )
        )
        // The panel alone decides the window's size. As the window's content
        // view, a hosting view resizes the window itself to follow a SwiftUI
        // animation (`updateAnimatedWindowSize`) — with the shape on a spring
        // and the panel setting the frame too, the two fought until AppKit
        // gave up on the constraint pass and ended the application. Inside a
        // plain container it only fills what it is given.
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        let container = NSView()
        container.addSubview(host)
        panel.contentView = container
        host.frame = container.bounds

        super.init(window: panel)

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

        // Open, the page shown decides the height, and a track loading or
        // going away adds or removes the music page and its dots.
        Publishers.CombineLatest(music.$loaded.map { $0 != nil }.removeDuplicates(), pages.$selected)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.store.presentation == .expanded else { return }
                self.positionPanel(for: .expanded, animated: true)
            }
            .store(in: &observers)

        watchPageGestures()

        metrics.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.positionPanel(for: self.store.presentation, animated: false)
            }
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
        window?.sharingType = allowed ? .readOnly : .none
        UserDefaults.standard.set(allowed, forKey: "allowScreenSharing")
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
        let overSurface = surface.contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents == overSurface { panel.ignoresMouseEvents = !overSurface }

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
        guard !region.contains(NSEvent.mouseLocation) else {
            absentTicks = 0
            presentTicks += 1
            if presentTicks >= Self.presentTicksBeforeOpen { store.expand() }
            return
        }

        presentTicks = 0

        // A pinned surface was asked for. It waits to be dismissed.
        guard store.presentation == .expanded, !store.isPinned else {
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

    // MARK: - Pages

    /// Moving between the expanded surface's pages: a two-finger swipe, and —
    /// for anyone without a trackpad — the arrow keys while it is pinned.
    /// VoiceOver has its own actions on the column.
    private func watchPageGestures() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === self.window else { return event }
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
        store.presentation == .expanded && music.loaded != nil
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

    private func positionPanel(
        for presentation: CapacityNotchStore.Presentation,
        animated: Bool
    ) {
        guard let panel = window, let screen = metrics.screen else { return }

        let geometry = metrics.geometry
        let openWidth = geometry.surfaceWidth()
        let size = switch presentation {
        case .compact:
            NSSize(
                width: geometry.compactWidth(),
                height: geometry.menuBarHeight + (showsMusicRow ? MusicType.rowHeight : 0)
            )
        case .expanded:
            NSSize(width: openWidth, height: expandedHeight(on: screen, width: openWidth))
        }
        let radius: CGFloat = presentation == .expanded ? 38 : 28

        // The window keeps one size, and only the black shape inside it
        // moves. A window resized under a SwiftUI animation left the layout
        // a step behind it, and the shape was drawn where the old window had
        // been — above the screen or off to one side. So the window is sized
        // once for the open surface with room for the spring's overshoot,
        // and grows, without animation, only if the content outgrows it.
        let room = NSSize(
            width: max(panel.frame.width, geometry.surfaceWidth() + Self.overshoot * 2),
            height: max(panel.frame.height, size.height + Self.overshoot, Self.minimumRoomHeight)
        )
        let frame = Self.frame(of: room, on: screen)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }

        guard animated else {
            shape.size = size
            shape.radius = radius
            return
        }

        let motion = SurfaceType.surfaceMotion(
            opening: presentation == .expanded,
            reduced: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        withAnimation(motion) {
            shape.size = size
            shape.radius = radius
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
    /// fullscreen application, where the strip stands alone.
    private var showsMusicRow: Bool {
        music.shown != nil && !metrics.isFullscreen
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
                page: pages.selected,
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

private final class NotchPanel: NSPanel {
    var dismiss: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Escape closes a pinned surface, the way Escape closes anything.
    override func cancelOperation(_ sender: Any?) {
        dismiss?()
    }
}
