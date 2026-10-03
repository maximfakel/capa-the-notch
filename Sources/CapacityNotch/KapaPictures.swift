import AppKit
import CapacityNotchCore
import SwiftUI

/// Kapa without opening the notch: every pose, the places it stands, its
/// movements frame by frame (`CAPACITY_NOTCH_DUMP_KAPA=<folder>`), and a live
/// window of it moving, which reports what it costs
/// (`CAPACITY_NOTCH_KAPA_PLAYGROUND=<seconds>`).
@MainActor
enum KapaPictures {
    static func draw(into folder: String) {
        drawSheet(into: folder)
        drawFilms(into: folder)
        drawPlaces(into: folder)
    }

    // MARK: Every pose

    private static func drawSheet(into folder: String) {
        for (size, name) in [(CGFloat(120), "kapa-sheet.png"), (26, "kapa-sheet-mini.png")] {
            let columns = 6
            let cell = size * 1.3
            let rows = (KapaExpression.allCases.count + columns - 1) / columns
            let sheet = VStack(spacing: 0) {
                ForEach(0 ..< rows, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0 ..< columns, id: \.self) { column in
                            let index = row * columns + column
                            Group {
                                if index < KapaExpression.allCases.count {
                                    frame(KapaExpression.allCases[index], size: size, at: 0, moving: false)
                                } else {
                                    Color.clear
                                }
                            }
                            .frame(width: cell, height: cell)
                        }
                    }
                }
            }
            .background(Color.black)
            save(sheet, named: name, into: folder)
        }
    }

    // MARK: Movements, frame by frame

    /// One row per movement, eight moments across it, so a movement can be
    /// read off a still picture.
    private static func drawFilms(into folder: String) {
        let size: CGFloat = 96
        let films: [(String, KapaExpression, Double, (KapaEngine, Int) -> Void)] = [
            // Two beats of nodding.
            ("music", .music, 60 / KapaMotion.musicTempo * 2 / 7, { _, _ in }),
            // A file coming closer, from far off to over the mouth.
            ("drag", .dropReady, 0.12, { engine, frame in
                let far = CGPoint(x: 330, y: -60)
                let near = CGPoint(x: 120, y: 110)
                let p = Double(frame) / 7
                engine.frame = CGRect(x: 72, y: 72, width: size, height: size)
                let point = CGPoint(x: far.x + (near.x - far.x) * p, y: far.y + (near.y - far.y) * p)
                engine.dragPoint = { point }
            }),
            // Eating it.
            ("gulp", .dropReady, KapaMotion.gulpLength / 7, { _, _ in }),
            // A tap.
            ("boop", .rest, KapaMotion.boopLength / 6, { _, _ in }),
            // Hello.
            ("hello", .hello, KapaMotion.duration(of: .hop) / 6, { _, _ in }),
            // A dictation that failed.
            ("failed", .failed, KapaMotion.shakeLength / 6, { _, _ in }),
        ]
        for (name, expression, step, prepare) in films {
            let engine = KapaEngine()
            engine.frame = CGRect(x: 0, y: 0, width: size, height: size)
            let start = 1000.0
            // Already in the pose before the film starts, so it opens on the
            // movement rather than on the blink that brings the pose in.
            engine.step(at: start - 1, inputs: inputs(.rest, size: size, moving: true))
            engine.step(at: start - 0.5, inputs: inputs(expression, size: size, moving: true))
            engine.step(at: start - 0.2, inputs: inputs(expression, size: size, moving: true))
            switch name {
            case "gulp":
                engine.step(at: start, inputs: inputs(expression, size: size, moving: true, swallowedAt: Date(timeIntervalSinceReferenceDate: start)))
            case "boop":
                engine.step(at: start, inputs: inputs(expression, size: size, moving: true))
                engine.boop()
            case "hello", "failed":
                // Entered at the start of the film.
                let fresh = KapaEngine()
                fresh.step(at: start - 1, inputs: inputs(.rest, size: size, moving: true))
                fresh.step(at: start - 0.001, inputs: inputs(expression, size: size, moving: true))
                fresh.step(at: start, inputs: inputs(expression, size: size, moving: true))
                strip(of: fresh, name: name, expression: expression, start: start, step: step, size: size, prepare: prepare, folder: folder)
                continue
            default:
                break
            }
            strip(of: engine, name: name, expression: expression, start: start, step: step, size: size, prepare: prepare, folder: folder)
        }
    }

    private static func strip(
        of engine: KapaEngine, name: String, expression: KapaExpression, start: Double, step: Double,
        size: CGFloat, prepare: (KapaEngine, Int) -> Void, folder: String
    ) {
        var frames: [Image] = []
        for index in 0 ..< 8 {
            prepare(engine, index)
            let time = start + Double(index) * step
            // Stepped at 30 a second up to the frame, as the timeline would.
            var t = time - step
            while t < time {
                t = min(time, t + 1.0 / 30)
                engine.step(at: t, inputs: inputs(expression, size: size, moving: true, swallowedAt: name == "gulp" ? Date(timeIntervalSinceReferenceDate: start) : nil))
            }
            let still = KapaFrame(engine: engine, size: size).frame(width: size * 1.5, height: size * 1.5).background(Color.black)
            let renderer = ImageRenderer(content: still)
            renderer.scale = 2
            if let image = renderer.cgImage { frames.append(Image(decorative: image, scale: 2)) }
        }
        let row = HStack(spacing: 0) { ForEach(Array(frames.enumerated()), id: \.offset) { $0.element } }.background(Color.black)
        save(row, named: "film-\(name).png", into: folder)
    }

    private static func inputs(_ expression: KapaExpression, size: CGFloat, moving: Bool, swallowedAt: Date? = nil) -> KapaEngine.Inputs {
        var face = KapaFace.of(expression)
        // The drop tab's Kapa has no file of its own: the one dragged is real.
        if moving, expression == .dropReady { face.badge = .none }
        return KapaEngine.Inputs(face: face, expression: expression, level: 0, swallowedAt: swallowedAt, moving: moving, size: size)
    }

    private static func frame(_ expression: KapaExpression, size: CGFloat, at time: Double, moving: Bool) -> some View {
        let engine = KapaEngine()
        engine.step(at: time, inputs: inputs(expression, size: size, moving: moving))
        return KapaFrame(engine: engine, size: size)
    }

    // MARK: Where Kapa stands

    /// The places, drawn in a window off screen and read back from its
    /// layers, since parts of them — the artwork, the equaliser — are views
    /// a renderer cannot draw.
    private static func drawPlaces(into folder: String) {
        let now = Date()
        let low = CapacitySnapshot(
            provider: .codex, capturedAt: now,
            windows: [
                QuotaWindow(id: "a", label: "5 hour", durationMinutes: 300, usedFraction: 0.96, resetsAt: now.addingTimeInterval(2160)),
                QuotaWindow(id: "b", label: "Weekly", durationMinutes: 10_080, usedFraction: 0.31, resetsAt: now.addingTimeInterval(187_200)),
            ],
            connectionState: .fresh
        )
        let fine = CapacitySnapshot(provider: .claudeCode, capturedAt: now, windows: [
            QuotaWindow(id: "a", label: "5 hour", durationMinutes: 300, usedFraction: 0.24, resetsAt: now.addingTimeInterval(13_000)),
            QuotaWindow(id: "b", label: "Weekly", durationMinutes: 10_080, usedFraction: 0.89, resetsAt: now.addingTimeInterval(7_000)),
        ], connectionState: .fresh)
        let track = NowPlaying(
            title: "Mad Technology", artist: "CZARFACE, Frankie Pulitzer, Method Man",
            player: "com.google.Chrome", isPlaying: true, duration: 224, elapsed: 46,
            elapsedAt: now, rate: 1
        )
        let suite = "capacity-notch-kapa-dump-\(UUID())"
        let demo = UserDefaults(suiteName: suite).map { Preferences(defaults: $0) } ?? Preferences()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        demo.teleprompterEnabled = true
        demo.replaceScript(with: TeleprompterController.sampleScript)
        let teleprompter = TeleprompterController(preferences: demo, registersShortcuts: false)
        let places: [(String, CGSize, AnyView)] = [
            ("place-teleprompter.png", CGSize(width: 560, height: 152), AnyView(TeleprompterPage(teleprompter: teleprompter))),
            ("place-drop.png", CGSize(width: 524, height: 108), AnyView(ShelfDropArea(
                title: L("Drag files here to keep them at hand"),
                detail: L("Up to 20 files. The Shelf empties when CapaTheNotch quits."), near: false))),
            ("place-drop-near.png", CGSize(width: 524, height: 108), AnyView(ShelfDropArea(
                title: L("Drag files here to keep them at hand"),
                detail: L("Up to 20 files. The Shelf empties when CapaTheNotch quits."), near: true))),
            ("place-cards.png", CGSize(width: 560, height: 152), AnyView(DetailCapacityView(snapshots: [low, fine], now: now, connect: { _ in }, refresh: { _ in }))),
            ("place-nothing-connected.png", CGSize(width: 560, height: 152), AnyView(DetailCapacityView(snapshots: UnreadCapacity.snapshots(), now: now, connect: { _ in }, refresh: { _ in }))),
            ("place-music-row.png", CGSize(width: 410, height: MusicType.rowHeight), AnyView(CompactMusicRow(track: track, width: 410, send: { _ in }))),
            ("place-music-page.png", CGSize(width: 560, height: 150), AnyView(MusicPage(track: track, now: now, send: { _ in }))),
        ]
        for (name, size, view) in places {
            let host = NSHostingView(rootView: view.foregroundStyle(.white).frame(width: size.width, height: size.height).background(Color.black))
            host.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: size.width, height: size.height), styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            window.orderFrontRegardless()
            host.layoutSubtreeIfNeeded()
            host.display()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            guard let layer = host.layer,
                  let context = CGContext(
                    data: nil, width: Int(size.width * 2), height: Int(size.height * 2), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { continue }
            // The hosting view's layer is flipped; the picture is not.
            context.translateBy(x: 0, y: size.height * 2)
            context.scaleBy(x: 2, y: -2)
            layer.render(in: context)
            window.orderOut(nil)
            if let image = context.makeImage() {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: folder).appendingPathComponent(name))
            }
        }
    }

    private static func save(_ view: some View, named name: String, into folder: String) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: folder).appendingPathComponent(name))
    }

    // MARK: Live

    private static var playground: NSWindow?
    private static var playgroundTimer: Timer?

    /// A window of Kapas moving as they would on the surface — nodding to
    /// music, eating a file dragged round and dropped every three seconds,
    /// listening to a level that rises and falls — for `seconds`, then the
    /// share of a core the process used, on standard error, and quit.
    static func play(for seconds: Double) {
        let model = PlaygroundModel()
        // One Kapa nodding to music, as the surface shows it most often, to
        // measure; or every movement at once, to watch.
        let solo = ProcessInfo.processInfo.environment["CAPACITY_NOTCH_KAPA_SOLO"] == "1"
        let content = PlaygroundView(model: model, solo: solo)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 640, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "Kapa"
        window.contentView = NSHostingView(rootView: content)
        if let screen = NSScreen.main {
            window.setFrameOrigin(CGPoint(x: screen.frame.midX - 320, y: screen.frame.midY - 150))
        }
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        playground = window

        let started = Date()
        let cpuAtStart = cpuSeconds()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { _ in
            MainActor.assumeIsolated { if !solo { model.tick(Date().timeIntervalSince(started)) } }
        }
        RunLoop.main.add(timer, forMode: .common)
        playgroundTimer = timer

        // What the Kapas cost, measured after a second to settle in.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let from = cpuSeconds()
            let at = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + max(seconds - 1, 1)) {
                let used = cpuSeconds() - from
                let wall = Date().timeIntervalSince(at)
                FileHandle.standardError.write(Data(String(
                    format: "kapa playground: %.1f%% of a core over %.0f s (%.2f s CPU; %.2f s since launch)\n",
                    used / wall * 100, wall, used, cpuSeconds() - cpuAtStart
                ).utf8))
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }
}

/// One frame of an engine, as it stands, without stepping it.
private struct KapaFrame: View {
    let engine: KapaEngine
    let size: CGFloat

    var body: some View {
        Canvas { context, canvas in
            engine.draw(in: &context, canvas: canvas, size: size, outline: nil)
        }
        .frame(width: size * KapaEngine.overhang, height: size * KapaEngine.overhang)
        .frame(width: size, height: size)
    }
}

@MainActor
private final class PlaygroundModel: ObservableObject {
    @Published var level = 0.0
    @Published var swallowedAt: Date?

    func tick(_ elapsed: Double) {
        level = max(0, sin(elapsed * 5) * 0.5 + sin(elapsed * 13) * 0.3)
        // A file circles in from the right, comes over the drop Kapa, and is
        // dropped; three seconds a round.
        let round = elapsed.truncatingRemainder(dividingBy: 3)
        if round < 2.3 {
            let p = round / 2.3
            let x = 470 - 250 * p
            let y = 40 + 120 * p + sin(p * .pi * 2) * 30
            KapaDrag.shared.point = CGPoint(x: x, y: y)
        } else {
            KapaDrag.shared.point = nil
            if swallowedAt == nil || Date().timeIntervalSince(swallowedAt!) > 1 { swallowedAt = Date() }
        }
    }
}

private struct PlaygroundView: View {
    @ObservedObject var model: PlaygroundModel
    let solo: Bool
    /// `CAPACITY_NOTCH_KAPA_SOLO_POSE`: rest, music, worried…; music if unset.
    private var soloExpression: KapaExpression {
        ProcessInfo.processInfo.environment["CAPACITY_NOTCH_KAPA_SOLO_POSE"].flatMap(KapaExpression.init(rawValue:)) ?? .music
    }

    var body: some View {
        if solo {
            KapaView(expression: soloExpression, size: 40)
                .frame(width: 640, height: 300)
                .background(Color.black)
        } else {
            everything
        }
    }

    private var everything: some View {
        VStack(spacing: 28) {
            HStack(spacing: 40) {
                labelled("music") { KapaView(expression: .music, size: 64) }
                labelled("rest — hover, tap") { KapaView(expression: .rest, size: 64) }
                labelled("drop") {
                    KapaView(expression: .dropReady, size: 64, showsBadge: false, swallowedAt: model.swallowedAt)
                }
                labelled("listening") { KapaView(expression: .listening, size: 64, level: model.level) }
            }
            HStack(spacing: 40) {
                labelled("worried") { KapaView(expression: .worried, size: 48) }
                labelled("waiting") { KapaView(expression: .waiting, size: 48) }
                labelled("thinking") { KapaView(expression: .thinking, size: 48) }
                labelled("mini") { KapaView(expression: .music, size: 26) }
            }
        }
        .padding(30)
        .frame(width: 640, height: 300)
        .background(Color.black)
        .foregroundStyle(.white)
    }

    private func labelled(_ text: String, @ViewBuilder _ kapa: () -> some View) -> some View {
        VStack(spacing: 8) {
            kapa()
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}
