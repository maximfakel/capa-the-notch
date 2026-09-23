import AppKit
import CapacityNotchCore
import Combine
import CoreGraphics
import SwiftUI

@MainActor
final class NotchPanelController: NSWindowController, NSWindowDelegate {
    private let store: CapacityNotchStore
    private let connect: (Provider) -> Void
    private let refresh: (Provider) -> Void
    private let metrics = SurfaceMetrics()
    private var observers: Set<AnyCancellable> = []
    private var pointerTimer: Timer?
    private var hideTimer: Timer?
    private var presentTicks = 0
    private var absentTicks = 0
    private var hide: SurfaceHide?

    private static let pointerInterval: TimeInterval = 0.1
    /// A pointer passing over the strip on its way somewhere else has not
    /// asked for anything. It must settle for this long before the surface
    /// opens.
    private static let presentTicksBeforeOpen = 3
    /// And a pointer that leaves for an instant has not left.
    private static let absentTicksBeforeClose = 2

    init(
        store: CapacityNotchStore,
        connect: @escaping (Provider) -> Void,
        refresh: @escaping (Provider) -> Void
    ) {
        self.store = store
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
        panel.contentView = NSHostingView(
            rootView: NotchRootView(
                store: store,
                metrics: metrics,
                connect: connect,
                refresh: refresh
            )
        )

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
        hide = nil
        hideTimer?.invalidate()
        hideTimer = nil

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
    }

    /// Opens the surface, as finishing onboarding does: the first thing the
    /// person should see is the Capacity they just connected.
    func open() {
        store.pin()
    }

    func toggleVisibility() {
        guard let window else { return }

        if window.isVisible {
            putAway()
        } else {
            show()
        }
    }

    /// Puts the surface away for a while. Providers keep being read, and it
    /// comes back on its own — nobody should have to remember to restore it.
    func hideForAnHour() {
        let hide = SurfaceHide(from: Date())
        self.hide = hide
        putAway()

        hideTimer?.invalidate()
        let timer = Timer(fire: hide.until, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.show() }
        }
        RunLoop.main.add(timer, forMode: .common)
        hideTimer = timer
    }

    var hiddenUntilText: String? {
        guard let hide, !hide.isOver(at: Date()) else { return nil }
        return hide.remainingText(at: Date())
    }

    private func putAway() {
        store.dismiss()
        window?.orderOut(nil)
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
        hideTimer?.invalidate()
        hideTimer = nil
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

        // Closed, the surface answers to its strip; open, to the whole of
        // itself. Both are the same width, so the region only ever grows
        // downwards and the two states cannot chase each other.
        guard !panel.frame.contains(NSEvent.mouseLocation) else {
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
            NSSize(width: geometry.compactWidth(), height: geometry.menuBarHeight)
        case .expanded:
            NSSize(width: openWidth, height: expandedHeight(on: screen, width: openWidth))
        }
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )

        guard animated else {
            panel.setFrame(frame, display: true)
            return
        }

        let opening = presentation == .expanded

        // Reduce Motion asks for the size change without the journey.
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.allowsImplicitAnimation = true
                panel.animator().setFrame(frame, display: true)
            }
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            // Unfolding is the gesture worth watching, so it takes its time
            // and decelerates into place. Folding away is not, so it is
            // brisk: a surface that lingers on the way out feels reluctant.
            // Half a second on the drawing's own curve, which is the same
            // ease the designer used for the width and the height together.
            context.duration = opening ? SurfaceType.openDuration : 0.26
            context.timingFunction = opening
                ? CAMediaTimingFunction(
                    controlPoints: Float(SurfaceType.openCurve.0),
                    Float(SurfaceType.openCurve.1),
                    Float(SurfaceType.openCurve.2),
                    Float(SurfaceType.openCurve.3)
                )
                : CAMediaTimingFunction(controlPoints: 0.4, 0, 0.7, 1)
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(frame, display: true)
        }
    }

    /// The expanded surface follows its content. A Provider that is
    /// disconnected explains itself in a sentence, and a fixed height would
    /// cut that sentence in half.
    private func expandedHeight(on screen: NSScreen, width: CGFloat) -> CGFloat {
        let minimumHeight = metrics.geometry.menuBarHeight + 180

        let measuring = NSHostingView(
            rootView: SurfaceColumn(
                snapshots: store.snapshots,
                geometry: metrics.geometry,
                now: Date(),
                isExpanded: true,
                connect: { _ in },
                refresh: { _ in },
                toggle: {}
            )
        )
        measuring.frame = NSRect(x: 0, y: 0, width: width, height: 0)
        measuring.layoutSubtreeIfNeeded()

        return min(max(measuring.fittingSize.height, minimumHeight), screen.visibleFrame.height)
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
