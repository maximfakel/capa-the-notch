import AppKit
import ApplicationServices
import IOKit.hid

// Ticket 14: which route sees a one-finger tap on the trackpad from anywhere?
//
//   swift run --package-path Spikes/TrackpadTap trackpad-tap-spike          guided, needs a finger
//   swift run --package-path Spikes/TrackpadTap trackpad-tap-spike probe    no finger: what loads, what is asked
//
// It only listens. Nothing it hears is swallowed, and nothing leaves this Mac;
// the guided run writes its table to Spikes/TrackpadTap/Results/.

struct TouchRecord {
    var fingersAtOnce = 1
    var start: Double
    var end: Double = 0
    var startX: Float, startY: Float
    var moved: Double = 0 // millimetres, furthest from where it went down
    var major: Float = 0, minor: Float = 0, total: Float = 0, pressure: Float = 0, density: Float = 0
    var duration: Double { end - start }
}

struct PhaseLog {
    var frames = 0
    var insaneFrames = 0
    var touches: [TouchRecord] = []
    var events: [String: Int] = [:]
    var monitorTouches = 0 // route 1: NSEvent.touches on globally monitored events
    var tapTouches = 0 // route 1, through a listen-only event tap
    var pressureStages: [Int: Int] = [:]
    var clickCounts: [Int] = []
}

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var logs: [String: PhaseLog] = [:]
    private var phase = "setup"
    private var active: [Int32: TouchRecord] = [:]
    private var lastDown = 0
    var surfaceMM: [UnsafeMutableRawPointer: (Double, Double)] = [:]

    func begin(_ name: String) { lock.withLock { phase = name; logs[name] = PhaseLog() } }
    func log(_ name: String) -> PhaseLog { lock.withLock { logs[name] ?? PhaseLog() } }

    func event(_ name: String, edit: ((inout PhaseLog) -> Void)? = nil) {
        lock.withLock {
            logs[phase, default: PhaseLog()].events[name, default: 0] += 1
            if let edit { edit(&logs[phase, default: PhaseLog()]) }
        }
    }

    func frame(device: UnsafeMutableRawPointer?, contacts: [Contact], time: Double) {
        lock.withLock {
            let (w, h) = device.flatMap { surfaceMM[$0] } ?? (160, 100)
            logs[phase, default: PhaseLog()].frames += 1
            if contacts.contains(where: { !$0.looksSane }) { logs[phase, default: PhaseLog()].insaneFrames += 1 }
            let down = contacts.filter(\.isDown)
            for contact in down {
                var record = active[contact.identifier] ?? TouchRecord(start: time, startX: contact.x, startY: contact.y)
                let dx = Double(contact.x - record.startX) * w, dy = Double(contact.y - record.startY) * h
                record.moved = max(record.moved, (dx * dx + dy * dy).squareRoot())
                record.fingersAtOnce = max(record.fingersAtOnce, down.count)
                record.major = max(record.major, contact.majorAxis)
                record.minor = max(record.minor, contact.minorAxis)
                record.total = max(record.total, contact.total)
                record.pressure = max(record.pressure, contact.pressure)
                record.density = max(record.density, contact.density)
                active[contact.identifier] = record
            }
            let ids = Set(down.map(\.identifier))
            for (id, var record) in active where !ids.contains(id) {
                record.end = time
                logs[phase, default: PhaseLog()].touches.append(record)
                active[id] = nil
            }
        }
    }
}

let recorder = Recorder()

let frameCallback: Multitouch.FrameCallback = { device, touches, count, timestamp, _ in
    guard let touches, count >= 0, count < 32 else {
        recorder.frame(device: device, contacts: [], time: timestamp)
        return
    }
    let contacts = (0..<Int(count)).map { Contact(touches, index: $0) }
    recorder.frame(device: device, contacts: contacts, time: timestamp)
}

// MARK: - What is granted, before and after

func permissions() -> String {
    func name(_ access: IOHIDAccessType) -> String {
        switch access {
        case kIOHIDAccessTypeGranted: "granted"
        case kIOHIDAccessTypeDenied: "denied"
        default: "not asked"
        }
    }
    return [
        "Input Monitoring (IOHIDCheckAccess listen): \(name(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)))",
        "Accessibility (AXIsProcessTrusted): \(AXIsProcessTrusted() ? "granted" : "not granted")",
        "Listen-event preflight (CGPreflightListenEventAccess): \(CGPreflightListenEventAccess() ? "granted" : "not granted")",
    ].joined(separator: "\n")
}

func trackpadSettings() -> String {
    func clicking(_ domain: String) -> String {
        guard let value = CFPreferencesCopyAppValue("Clicking" as CFString, domain as CFString) else { return "unset" }
        return "\(value)"
    }
    return [
        "Tap to click (built-in): \(clicking("com.apple.AppleMultitouchTrackpad"))",
        "Tap to click (Bluetooth): \(clicking("com.apple.driver.AppleBluetoothMultitouch.trackpad"))",
        "Double-click interval: \(NSEvent.doubleClickInterval) s",
    ].joined(separator: "\n")
}

// MARK: - Routes 1 and 2: global events

let monitored: NSEvent.EventTypeMask = [
    .leftMouseDown, .leftMouseUp, .pressure, .gesture, .beginGesture, .endGesture,
    .magnify, .swipe, .rotate, .smartMagnify, .directTouch, .scrollWheel,
]
let touchBearing: Set<NSEvent.EventType> = [.gesture, .beginGesture, .endGesture, .magnify, .swipe, .rotate, .directTouch]

func name(_ type: NSEvent.EventType) -> String {
    switch type {
    case .leftMouseDown: "leftMouseDown"
    case .leftMouseUp: "leftMouseUp"
    case .pressure: "pressure"
    case .gesture: "gesture"
    case .beginGesture: "beginGesture"
    case .endGesture: "endGesture"
    case .magnify: "magnify"
    case .swipe: "swipe"
    case .rotate: "rotate"
    case .smartMagnify: "smartMagnify"
    case .directTouch: "directTouch"
    case .scrollWheel: "scrollWheel"
    default: "type\(type.rawValue)"
    }
}

func monitor() -> Any? {
    NSEvent.addGlobalMonitorForEvents(matching: monitored) { event in
        let touches = touchBearing.contains(event.type) ? event.touches(matching: .any, in: nil).count : 0
        recorder.event("monitor." + name(event.type)) { log in
            log.monitorTouches += touches
            if event.type == .pressure { log.pressureStages[event.stage, default: 0] += 1 }
            if event.type == .leftMouseDown { log.clickCounts.append(event.clickCount) }
        }
    }
}

/// A listen-only tap for the event types a global monitor might not be
/// given: gestures, pressure and direct touches, and the clicks beside them.
func eventTap() -> CFMachPort? {
    let types: [UInt64] = [1, 2, 18, 19, 20, 29, 30, 31, 32, 34, 37]
    let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1) }
    let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
        eventsOfInterest: mask,
        callback: { _, type, event, _ in
            if let ns = NSEvent(cgEvent: event) {
                let touches = touchBearing.contains(ns.type) ? ns.touches(matching: .any, in: nil).count : 0
                recorder.event("tap." + name(ns.type)) { $0.tapTouches += touches }
            } else {
                recorder.event("tap.raw\(type.rawValue)")
            }
            return Unmanaged.passUnretained(event)
        },
        userInfo: nil
    )
    if let tap {
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }
    return tap
}

// MARK: - The run

struct Phase {
    let key: String
    let say: String
    let seconds: Double
}

let guided = [
    Phase(key: "rest", say: "Hands OFF the trackpad.", seconds: 4),
    Phase(key: "tap", say: "Tap twice with ONE finger, lightly, without pressing down — three times, a second apart. Keep the pointer over the empty desktop.", seconds: 10),
    Phase(key: "press", say: "Double-click by PRESSING the trackpad down with one finger — three times.", seconds: 10),
    Phase(key: "two", say: "Tap twice with TWO fingers together — three times.", seconds: 8),
    Phase(key: "hold", say: "Touch with one finger and HOLD for a second — three times.", seconds: 8),
    Phase(key: "palm", say: "Rest your PALM (or the side of your hand) on the trackpad and lift it — three times.", seconds: 8),
    Phase(key: "scroll", say: "Scroll with two fingers, up and down.", seconds: 5),
]

func fmt(_ value: Double, _ digits: Int = 2) -> String { String(format: "%.\(digits)f", value) }

func report(_ phases: [Phase], header: String) -> String {
    var lines = [header, ""]
    for phase in phases {
        let log = recorder.log(phase.key)
        lines.append("## \(phase.key) — \(phase.say)")
        lines.append("MultitouchSupport: \(log.frames) frames\(log.insaneFrames > 0 ? ", \(log.insaneFrames) with values outside the expected layout" : ""), \(log.touches.count) touches")
        for touch in log.touches.prefix(16) {
            lines.append("  touch: fingers \(touch.fingersAtOnce), \(fmt(touch.duration * 1000, 0)) ms, moved \(fmt(touch.moved, 1)) mm, axes \(fmt(Double(touch.major), 1))×\(fmt(Double(touch.minor), 1)), total \(fmt(Double(touch.total))), pressure \(fmt(Double(touch.pressure))), density \(fmt(Double(touch.density)))")
        }
        let singles = log.touches.filter { $0.fingersAtOnce == 1 }
        let gaps = zip(singles, singles.dropFirst()).map { $1.start - $0.end }
        if !gaps.isEmpty { lines.append("  lift-to-touch gaps: \(gaps.map { fmt($0 * 1000, 0) + " ms" }.joined(separator: ", "))") }
        let events = log.events.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }
        lines.append("Global events: \(events.isEmpty ? "none" : events.joined(separator: ", "))")
        lines.append("  touches on monitored events (route 1): \(log.monitorTouches); through the event tap: \(log.tapTouches)")
        if !log.pressureStages.isEmpty {
            lines.append("  pressure stages: \(log.pressureStages.sorted { $0.key < $1.key }.map { "stage \($0.key) ×\($0.value)" }.joined(separator: ", "))")
        }
        if !log.clickCounts.isEmpty { lines.append("  click counts: \(log.clickCounts.map(String.init).joined(separator: " "))") }
        lines.append("")
    }

    let tap = recorder.log(probing ? "rest" : "tap")
    lines.append("## Verdict, from the tap phase")
    lines.append("Route 1 (NSEvent touches, global): \(tap.monitorTouches + tap.tapTouches > 0 ? "saw \(tap.monitorTouches + tap.tapTouches) touches" : "saw no touches") — needs one-finger touches to time two taps.")
    let r2 = (tap.events["monitor.pressure"] ?? 0) + (tap.events["monitor.gesture"] ?? 0) + (tap.events["tap.pressure"] ?? 0) + (tap.events["tap.gesture"] ?? 0)
    lines.append("Route 2 (.pressure / .gesture, global): \(r2) events during light taps.")
    let singleTaps = tap.touches.filter { $0.fingersAtOnce == 1 && $0.duration < 0.35 }
    lines.append("Route 3 (MultitouchSupport): \(singleTaps.count) one-finger touches under 350 ms (six expected).")
    return lines.joined(separator: "\n")
}

let arguments = CommandLine.arguments.dropFirst()
let probing = arguments.first == "probe"
// `probe 60` listens for a minute to whatever the trackpad is given; with
// SPIKE_OUT set, the table is written there too (for a run through `open`,
// whose standard output goes nowhere).
let probeSeconds = arguments.dropFirst().first.flatMap(Double.init) ?? 3
let probeOut = ProcessInfo.processInfo.environment["SPIKE_OUT"]

setvbuf(stdout, nil, _IONBF, 0)
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

var header = ["# Trackpad tap spike, \(ISO8601DateFormatter().string(from: Date()))",
              "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
              trackpadSettings(),
              "",
              "Before:", permissions()]
print(header.joined(separator: "\n"))

var multitouch: Multitouch?
switch Multitouch.open() {
case let .success(opened):
    multitouch = opened
    opened.startAll(frameCallback)
    var lines = ["", "MultitouchSupport opened; \(opened.devices.count) device(s):"]
    for device in opened.devices {
        recorder.surfaceMM[device.device] = (Double(device.width) / 100, Double(device.height) / 100)
        lines.append("  built-in \(device.builtIn), family \(device.familyID), surface \(fmt(Double(device.width) / 100, 1))×\(fmt(Double(device.height) / 100, 1)) mm, MTDeviceStart → \(device.startStatus)")
    }
    print(lines.joined(separator: "\n"))
    header += lines
case let .failure(error):
    print("MultitouchSupport could not be opened: \(error)")
    header.append("MultitouchSupport could not be opened: \(error)")
}

let multitouchOnly = ProcessInfo.processInfo.environment["SPIKE_MULTITOUCH_ONLY"] == "1"
let globalMonitor = multitouchOnly ? nil : monitor()
// Off unless asked for: a listen-only event tap, even for mouse and gesture
// events alone, asks macOS for Input Monitoring (seen on 27.0.1), and the
// person running this should not be prompted by surprise.
let wantsTap = ProcessInfo.processInfo.environment["SPIKE_EVENT_TAP"] == "1"
let tap = multitouchOnly || !wantsTap ? nil : eventTap()
let routes = multitouchOnly ? "Global monitor and event tap: skipped (SPIKE_MULTITOUCH_ONLY)" : "Global monitor: \(globalMonitor == nil ? "refused" : "installed"); listen-only event tap: \(wantsTap ? (tap == nil ? "refused" : "installed") : "not tried (SPIKE_EVENT_TAP=1 tries it, and asks for Input Monitoring)")"
print(routes)
header.append(routes)

func finish(_ phases: [Phase]) {
    if let multitouch { multitouch.stopAll(frameCallback) }
    let after = "\nAfter:\n" + permissions()
    print(after)
    let text = report(phases, header: (header + [after]).joined(separator: "\n"))
    print("\n" + text)
    if probing, let probeOut {
        try? text.write(toFile: probeOut, atomically: true, encoding: .utf8)
    }
    if !probing {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Results")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let file = folder.appendingPathComponent("\(stamp).txt")
        try? text.write(to: file, atomically: true, encoding: .utf8)
        print("\nWritten to \(file.path)")
    }
    exit(0)
}

func run(_ phases: [Phase], index: Int = 0) {
    guard index < phases.count else { return finish(phases) }
    let phase = phases[index]
    print("\n[\(index + 1)/\(phases.count)] \(phase.say)")
    if !probing { print("   get ready…") }
    DispatchQueue.main.asyncAfter(deadline: .now() + (probing ? 0 : 2)) {
        recorder.begin(phase.key)
        print("   GO — \(Int(phase.seconds)) seconds")
        DispatchQueue.main.asyncAfter(deadline: .now() + phase.seconds) {
            print("   done")
            run(phases, index: index + 1)
        }
    }
}

DispatchQueue.main.async {
    run(probing ? [Phase(key: "rest", say: "Probe: listening, nobody asked to touch.", seconds: probeSeconds)] : guided)
}
app.run()
