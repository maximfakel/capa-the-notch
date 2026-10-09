import AppKit
import CapacityNotchCore
import Combine
import Foundation

/// Opens the surface on two taps of one finger, read from the trackpad's own
/// touches (ticket 14).
///
/// The touches come from MultitouchSupport, a private framework (ADR 0004):
/// opened at run time, so a Mac where it is missing or changed loses this and
/// nothing else. Off until asked for. It only listens — the events the taps
/// produce reach the application under the pointer as they always did.
@MainActor
final class TrackpadTapController: ObservableObject {
    @Published private(set) var status: TrackpadTapStatus = .off
    /// Called on the main thread when two taps have been read.
    var onDoubleTap: (() -> Void)?

    private var reader: MultitouchReader?
    private var monitors: [Any] = []
    private var wakeObserver: NSObjectProtocol?
    private var silence = TrackpadSilence()
    /// A silence is answered once by starting the devices again (a trackpad
    /// connected since, a driver restarted) before it is reported.
    private var restartedForSilence = false
    /// Two taps open the surface a moment after the second lift, so a
    /// physical click reported late can still call it off, and the click a
    /// tap may produce has landed before the surface takes the keyboard.
    private var pendingOpen: DispatchWorkItem?
    private static let openDelay: TimeInterval = 0.2

    /// The hands are on the keyboard (`TrackpadTyping`).
    private static var typing: Bool {
        TrackpadTyping.suppresses(
            secondsSinceKeyDown: CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        )
    }

    var isOn: Bool { status != .off }

    func setEnabled(_ enabled: Bool) {
        if enabled { start() } else { stop() }
    }

    private func start() {
        guard reader == nil else { return }
        installMonitors()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Multitouch devices are not always given back after sleep.
            MainActor.assumeIsolated { self?.restartReader() }
        }
        startReader()
    }

    private func stop() {
        pendingOpen?.cancel()
        pendingOpen = nil
        reader?.stop()
        reader = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        silence.reset()
        restartedForSilence = false
        status = .off
    }

    private func startReader() {
        let tuning = TapTuning.matching(doubleClickInterval: NSEvent.doubleClickInterval)
        let reader = MultitouchReader(tuning: tuning) { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(event) }
            }
        }
        self.reader = reader
        status = switch reader.start() {
        case .started: .listening
        case .noDevices: .noTrackpad
        case .unreadable: .unreadable
        }
    }

    private func restartReader() {
        guard reader != nil else { return }
        reader?.stop()
        reader = nil
        silence.reset()
        startReader()
    }

    private func handle(_ event: MultitouchReader.Event) {
        guard reader != nil else { return }
        switch event {
        case .doubleTap:
            pendingOpen?.cancel()
            pendingOpen = nil
            guard !Self.typing else { return }
            let open = DispatchWorkItem { [weak self] in
                self?.pendingOpen = nil
                // A key pressed in the moment before the surface opens
                // calls it off too.
                guard !Self.typing else { return }
                self?.onDoubleTap?()
            }
            pendingOpen = open
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.openDelay, execute: open)
        case .layoutChanged:
            reader?.stop()
            status = .unreadable
        }
    }

    // MARK: - Watching, never taking

    private func installMonitors() {
        // A physical press: the touch under it was a click, not a tap. A
        // Force Touch trackpad reports it as pressure; with Tap to click
        // off, any trackpad's mouse-down is one too.
        let pressMask: NSEvent.EventTypeMask = [.pressure, .leftMouseDown]
        let onPress: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated { self?.observePress(event) }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: pressMask, handler: onPress) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: pressMask, handler: { event in
            onPress(event)
            return event
        }) {
            monitors.append(local)
        }
        // A scroll beginning on a multitouch surface proves fingers are on
        // it; with no frames near several in a row, the frames have stopped.
        let onScroll: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated { self?.observeScroll(event) }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: onScroll) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { event in
            onScroll(event)
            return event
        }) {
            monitors.append(local)
        }
    }

    private func observePress(_ event: NSEvent) {
        let pressed = switch event.type {
        case .pressure: event.stage >= 1
        case .leftMouseDown: !Self.tapToClick
        default: false
        }
        guard pressed else { return }
        reader?.press()
        pendingOpen?.cancel()
        pendingOpen = nil
    }

    private func observeScroll(_ event: NSEvent) {
        guard let reader, event.phase == .began, event.hasPreciseScrollingDeltas else { return }
        // A multitouch surface where none was found: one has been connected.
        if status == .noTrackpad { return restartReader() }
        let now = ProcessInfo.processInfo.systemUptime
        let quiet = silence.trackpadScrolled(at: now, lastFrame: reader.lastFrame)
        if let lastFrame = reader.lastFrame, abs(now - lastFrame) <= silence.window {
            // Answering again: a later silence earns its own restart.
            restartedForSilence = false
            if status == .silent { status = .listening }
        }
        guard quiet, status == .listening else { return }
        if restartedForSilence {
            status = .silent
        } else {
            restartedForSilence = true
            restartReader()
        }
    }

    /// Whether a tap on the trackpad is itself a click (System Settings ›
    /// Trackpad › Tap to click), for the built-in or a Bluetooth trackpad.
    private static var tapToClick: Bool {
        ["com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad"].contains { domain in
            (CFPreferencesCopyAppValue("Clicking" as CFString, domain as CFString) as? NSNumber)?.boolValue == true
        }
    }
}

/// MultitouchSupport, opened with `dlopen` and read frame by frame.
///
/// Frames arrive on the framework's own thread; each is turned into a
/// `TouchFrame` and given to the recogniser there, under a lock, and only a
/// completed double tap crosses to the main thread.
final class MultitouchReader: @unchecked Sendable {
    enum Event { case doubleTap, layoutChanged }
    enum Outcome { case started, noDevices, unreadable }

    typealias Device = UnsafeMutableRawPointer
    private typealias FrameCallback = @convention(c) (Device?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Void
    private typealias CreateList = @convention(c) () -> Unmanaged<CFMutableArray>?
    private typealias Register = @convention(c) (Device, FrameCallback) -> Void
    private typealias Start = @convention(c) (Device, Int32) -> Int32
    private typealias Stop = @convention(c) (Device) -> Int32
    private typealias Dimensions = @convention(c) (Device, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32

    private struct Symbols {
        let createList: CreateList
        let register: Register
        let unregister: Register
        let start: Start
        let stop: Stop
        let dimensions: Dimensions?
    }

    private static let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
    /// One contact, as every open reader of this framework lays it out.
    private static let stride = 96
    /// Frames with values no contact could have before the layout is called
    /// changed, rather than one odd frame.
    private static let insaneFramesTolerated = 10

    /// The C callback carries no context, so the one reader running is kept
    /// here. There is only ever one.
    nonisolated(unsafe) private static var current: MultitouchReader?
    private static let currentLock = NSLock()

    private let lock = NSLock()
    private var recogniser: TrackpadDoubleTap
    private var surfaces: [Device: (width: Double, height: Double)] = [:]
    private var list: CFMutableArray?
    private var symbols: Symbols?
    private var insaneFrames = 0
    private var _lastFrame: TimeInterval?
    private let report: (Event) -> Void

    init(tuning: TapTuning, report: @escaping (Event) -> Void) {
        recogniser = TrackpadDoubleTap(tuning: tuning)
        self.report = report
    }

    /// When the last frame arrived, on `systemUptime`'s clock.
    var lastFrame: TimeInterval? { lock.withLock { _lastFrame } }

    func start() -> Outcome {
        guard let symbols = Self.open() else { return .unreadable }
        guard let list = symbols.createList()?.takeRetainedValue(), CFArrayGetCount(list) > 0 else { return .noDevices }
        self.symbols = symbols
        self.list = list
        Self.currentLock.withLock { Self.current = self }
        var started = 0
        for index in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
            let device = UnsafeMutableRawPointer(mutating: raw)
            var width: Int32 = 0, height: Int32 = 0
            _ = symbols.dimensions?(device, &width, &height)
            // Hundredths of a millimetre; a trackpad's size where it says none.
            lock.withLock {
                surfaces[device] = width > 0 && height > 0 ? (Double(width) / 100, Double(height) / 100) : (160, 100)
            }
            symbols.register(device, Self.callback)
            if symbols.start(device, 0) == 0 { started += 1 }
        }
        return started > 0 ? .started : .unreadable
    }

    func stop() {
        Self.currentLock.withLock { if Self.current === self { Self.current = nil } }
        guard let symbols, let list else { return }
        for index in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
            let device = UnsafeMutableRawPointer(mutating: raw)
            symbols.unregister(device, Self.callback)
            _ = symbols.stop(device)
        }
        self.list = nil
        lock.withLock { recogniser.reset() }
    }

    /// The trackpad was pressed down, physically.
    func press() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.withLock { recogniser.press(at: now) }
    }

    private static func open() -> Symbols? {
        guard let handle = dlopen(path, RTLD_NOW) else { return nil }
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }
        guard let createList = symbol("MTDeviceCreateList", CreateList.self),
              let register = symbol("MTRegisterContactFrameCallback", Register.self),
              let unregister = symbol("MTUnregisterContactFrameCallback", Register.self),
              let start = symbol("MTDeviceStart", Start.self),
              let stop = symbol("MTDeviceStop", Stop.self)
        else { return nil }
        return Symbols(
            createList: createList, register: register, unregister: unregister, start: start, stop: stop,
            dimensions: symbol("MTDeviceGetSensorSurfaceDimensions", Dimensions.self)
        )
    }

    private static let callback: FrameCallback = { device, touches, count, _, _ in
        let reader = currentLock.withLock { current }
        reader?.receive(device: device, touches: touches, count: Int(count))
    }

    private func receive(device: Device?, touches: UnsafeMutableRawPointer?, count: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        var sane = (0..<64).contains(count) && (count == 0 || touches != nil)
        var contacts: [TouchContact] = []
        let surface = lock.withLock { device.flatMap { surfaces[$0] } } ?? (160, 100)
        if sane, let touches {
            for index in 0..<count {
                let p = touches + index * Self.stride
                let state = p.load(fromByteOffset: 20, as: Int32.self)
                let x = p.load(fromByteOffset: 32, as: Float.self)
                let y = p.load(fromByteOffset: 36, as: Float.self)
                guard (0...7).contains(state), (-0.2...1.2).contains(x), (-0.2...1.2).contains(y) else {
                    sane = false
                    break
                }
                // Making touch (3) or touching (4): on the glass, not hovering
                // above it or lifting off it.
                guard state == 3 || state == 4 else { continue }
                contacts.append(TouchContact(
                    id: Int(p.load(fromByteOffset: 16, as: Int32.self)),
                    x: Double(x) * surface.width,
                    y: Double(y) * surface.height,
                    size: Double(p.load(fromByteOffset: 60, as: Float.self))
                ))
            }
        }
        let event: Event? = lock.withLock {
            _lastFrame = now
            guard sane else {
                insaneFrames += 1
                return insaneFrames == Self.insaneFramesTolerated ? .layoutChanged : nil
            }
            return recogniser.observe(TouchFrame(time: now, contacts: contacts)) ? .doubleTap : nil
        }
        if let event { report(event) }
    }
}
