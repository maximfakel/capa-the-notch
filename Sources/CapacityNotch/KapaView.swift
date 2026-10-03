import AppKit
import CapacityNotchCore
import SwiftUI

/// Kapa, drawn (ADR 0006): the bell from "Kapa — 01 Character sheet", in the
/// sheet's own 100-unit square, scaled to `size`.
///
/// Drawn as Coucou draws Mochi: a SwiftUI `Canvas` under a `TimelineView`,
/// with a small engine stepping every frame (research §1.1). Unlike Coucou's,
/// the timeline runs only while Kapa can be seen and may move — at 30 frames
/// a second, not the display's 60 or 120 — and stops under Reduce Motion, on
/// a page that is not shown, and beside the Teleprompter.
struct KapaView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.kapaAwake) private var awake
    let expression: KapaExpression
    var size: CGFloat
    /// Where to look, when the place Kapa sits decides it — the capsule's
    /// orb is up and to the left.
    var look: KapaLook?
    /// Off where something else already says it: the capsule's orb turns
    /// green for done and red for failed.
    var showsBadge = true
    /// A ring of the background's colour round the body, where Kapa overlaps
    /// something drawn behind it.
    var outline: Color?
    /// A live level, 0 to 1: the microphone's, while dictation listens.
    var level: Double = 0
    /// When a file was last dropped for Kapa to eat (the Shelf's drop tab).
    var swallowedAt: Date?
    /// False where Kapa should hold still whatever else is true.
    var isAnimated = true
    /// Whether a tap boops it. Off where Kapa stands on something that takes
    /// the click itself — the capsule is a button.
    var isTappable = true

    @State private var engine = KapaEngine()
    /// Bumped when the pointer arrives or taps, to wake a resting timeline
    /// now rather than at its next blink.
    @State private var nudge = 0

    var body: some View {
        let running = isAnimated && awake && !reduceMotion
        TimelineView(KapaSchedule(engine: engine, running: running, nudge: nudge)) { timeline in
            Canvas { context, canvas in
                engine.step(
                    at: timeline.date.timeIntervalSinceReferenceDate,
                    inputs: KapaEngine.Inputs(
                        face: face,
                        expression: expression,
                        level: level,
                        swallowedAt: swallowedAt,
                        moving: running,
                        size: size
                    )
                )
                engine.draw(in: &context, canvas: canvas, size: size, outline: outline)
            }
            // Room above and beside for what floats off Kapa — notes, hearts,
            // a dropped file on its way in — without moving anything it
            // stands beside.
            .frame(width: size * KapaEngine.overhang, height: size * KapaEngine.overhang)
            .frame(width: size, height: size)
            .allowsHitTesting(false)
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case let .active(point):
                if engine.hover == nil { nudge += 1 }
                engine.hover = point
            case .ended:
                engine.hover = nil
            }
        }
        .onTapGesture {
            guard isTappable else { return }
            engine.boop()
            nudge += 1
        }
        .allowsHitTesting(running)
        .background(
            GeometryReader { geometry in
                let frame = geometry.frame(in: .global)
                Color.clear
                    .onAppear { engine.frame = frame }
                    .onChange(of: frame) { _, now in engine.frame = now }
            }
        )
        // Decorative: what Kapa shows, the surface already says in words.
        .accessibilityHidden(true)
    }

    private var face: KapaFace {
        var face = KapaFace.of(expression)
        if let look { face.look = look }
        if !showsBadge { face.badge = .none }
        return face
    }
}

/// Whether the place Kapa stands is on screen now: the open surface's pages
/// only while it is open and that page is shown, the rows under the strip
/// only while it is closed. Every page is built whether or not it is shown,
/// so without this a Kapa on a hidden page would keep drawing.
private struct KapaAwakeKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var kapaAwake: Bool {
        get { self[KapaAwakeKey.self] }
        set { self[KapaAwakeKey.self] = newValue }
    }
}

/// Kapa where the person has left it on, and `otherwise` where they turned
/// it off (Settings ▸ General).
struct WithKapa<Shown: View, Otherwise: View>: View {
    @AppStorage(KapaPreference.key) private var showsKapa = KapaPreference.defaultValue
    @ViewBuilder let shown: () -> Shown
    @ViewBuilder let otherwise: () -> Otherwise

    var body: some View {
        if showsKapa { shown() } else { otherwise() }
    }
}

extension WithKapa where Otherwise == EmptyView {
    init(@ViewBuilder shown: @escaping () -> Shown) {
        self.shown = shown
        self.otherwise = { EmptyView() }
    }
}

/// When Kapa draws: thirty times a second while anything on it moves, and
/// otherwise not until the next thing due — a blink, a glance, a note. A
/// Kapa at rest on the Capacity page costs a few frames every few seconds,
/// not thirty a second (research §3.4, where Coucou does not).
private struct KapaSchedule: TimelineSchedule {
    let engine: KapaEngine
    let running: Bool
    /// Only to make a new schedule, starting now, when it changes.
    let nudge: Int

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        Entries(engine: engine, next: startDate, running: running)
    }

    struct Entries: Sequence, IteratorProtocol {
        let engine: KapaEngine
        var upcoming: Date?
        let running: Bool

        init(engine: KapaEngine, next: Date, running: Bool) {
            self.engine = engine
            self.upcoming = next
            self.running = running
        }

        mutating func next() -> Date? {
            guard let date = upcoming else { return nil }
            guard running else {
                upcoming = nil
                return date
            }
            let engine = engine
            let after = MainActor.assumeIsolated { engine.nextFrame(after: date.timeIntervalSinceReferenceDate) }
            upcoming = Date(timeIntervalSinceReferenceDate: after)
            return date
        }
    }
}

/// Where a file being dragged over the surface is, in the surface's own
/// coordinates, for a Kapa that wants to look at it. A plain value read each
/// frame rather than published: a drag reports sixty times a second, and the
/// surface should not rebuild for each.
@MainActor
final class KapaDrag {
    static let shared = KapaDrag()
    var point: CGPoint?
}

// MARK: - The engine

/// Kapa's state between frames, stepped once a frame: the pose shown, the
/// pose wanted, and everything easing between them. Pure motion is in
/// `KapaMotion`; this keeps the clock and the inputs.
@MainActor
final class KapaEngine {
    struct Inputs {
        var face: KapaFace
        var expression: KapaExpression
        var level: Double
        var swallowedAt: Date?
        var moving: Bool
        var size: CGFloat
    }

    /// The canvas is this much larger than Kapa, centred on it.
    static let overhang: CGFloat = 1.7

    /// Set by the view: where Kapa stands, and the pointer over it.
    var frame: CGRect = .zero
    var hover: CGPoint?
    /// A file being dragged near, in the surface's coordinates; the shared
    /// one unless a picture supplies its own.
    var dragPoint: () -> CGPoint? = { KapaDrag.shared.point }

    private(set) var shown: KapaFace?
    private var expression = KapaExpression.rest
    private var last: Double?
    private var now = 0.0
    private var moving = false

    private var yaw = 0.0
    private var pitch = 0.0
    private var tilt = 0.0
    private var sx = 1.0
    private var sy = 1.0
    private var dy = 0.0
    private var mouth = 0.0
    private var mouthVelocity = 0.0

    private var blinkAt = -10.0
    private var secondBlinkAt: Double?
    private var nextBlink = 0.0
    private var swapping = false
    /// Whether it has ever moved: one never moved is drawn exactly as posed.
    private var hasMoved = false

    private var reaction: (kind: KapaFace.Reaction, at: Double)?
    private var boopAt = -10.0
    private var shakeAt = -10.0
    private var gulpAt: Double?
    private var lastSwallow: Date?
    private var lastSwallowAt: Double?

    private var hoverSince: Double?
    private var pleasedUntil = 0.0
    private var lastPleased = -10.0

    /// Where the eyes and body were last heading, to tell when they are
    /// there and the timeline can rest.
    private var settledAt = KapaLook.ahead
    private var bodyTarget = (tilt: 0.0, sx: 1.0, sy: 1.0, dy: 0.0)
    private var mouthTarget = 0.0

    private var wander = KapaLook.ahead
    private var nextWander = 0.0
    private var nextAmbient = 0.0
    private var particles: [Particle] = []

    private struct Particle {
        enum Kind { case note, heart, sparkle, sweat, sleep }
        var kind: Kind
        var born: Double
        var life: Double
        var x: Double
        var y: Double
        var drift: Double
    }

    /// A tap: squashed flat, a giggle with the eyes shut, and back.
    func boop() {
        boopAt = now
    }

    // MARK: Stepping

    func step(at time: Double, inputs: Inputs) {
        let dt = min(0.05, max(0, time - (last ?? time)))
        last = time
        now = time
        moving = inputs.moving

        // A new pose arrives inside a blink: the lids shut, the face changes
        // behind them, and they open on the new one — never a melt from one
        // expression into another (Coucou's way, research §1.5).
        var changedStill = false
        if shown == nil || !moving {
            if shown != inputs.face || expression != inputs.expression {
                enter(inputs.face, expression: inputs.expression, quietly: true)
                changedStill = true
            }
        } else if shown != inputs.face || expression != inputs.expression {
            if !swapping {
                swapping = true
                blinkAt = time
            }
            if KapaMotion.lid(sinceBlink: time - blinkAt) < 0.3 || time - blinkAt > KapaBlink.closing + KapaBlink.opening {
                enter(inputs.face, expression: inputs.expression, quietly: false)
            }
        }
        guard let shown else { return }

        if let swallowed = inputs.swallowedAt, swallowed != lastSwallow {
            lastSwallow = swallowed
            if moving {
                gulpAt = time
                lastSwallowAt = time
            }
        }
        if let gulpAt, time - gulpAt > KapaMotion.gulpLength {
            self.gulpAt = nil
            emit(.sparkle, count: 2)
        }

        guard moving else {
            settle(shown, snap: changedStill || !hasMoved)
            return
        }
        hasMoved = true

        blinkIfDue(shown)
        followTheEyes(shown, inputs: inputs, dt: dt)
        moveTheBody(shown, inputs: inputs, dt: dt)
        moveTheMouth(inputs: inputs, dt: dt)
        noticeThePointer()
        emitAmbient()
        particles.removeAll { time - $0.born > $0.life }
    }

    private func enter(_ face: KapaFace, expression: KapaExpression, quietly: Bool) {
        shown = face
        self.expression = expression
        swapping = false
        guard !quietly else { return }
        reaction = (face.reaction, now)
        switch expression {
        case .hello, .inserted: emit(.sparkle, count: 3)
        case .failed: shakeAt = now
        default: break
        }
    }

    /// Held still. A pose that changed is drawn as it stands; one already
    /// shown keeps the body where it was, its eyes open and nothing in the
    /// air — a page sliding away goes still rather than snapping back to rest
    /// in view as it leaves.
    private func settle(_ face: KapaFace, snap: Bool) {
        if snap {
            yaw = face.look.yaw
            pitch = face.look.pitch
            tilt = face.tilt
            sx = 1; sy = 1; dy = 0
        }
        swapping = false
        mouth = 0; mouthVelocity = 0
        particles = []
        hoverSince = nil
        reaction = nil
        gulpAt = nil
        boopAt = -10
        shakeAt = -10
        blinkAt = -10
    }

    private func blinkIfDue(_ face: KapaFace) {
        if let second = secondBlinkAt, now >= second {
            secondBlinkAt = nil
            blinkAt = now
        }
        guard now >= nextBlink else { return }
        nextBlink = now + KapaBlink.delay(.random(in: 0 ... 1))
        guard KapaBlink.blinks(face.eyes), gulpAt == nil else { return }
        blinkAt = now
        if KapaBlink.isDouble(.random(in: 0 ... 1)) { secondBlinkAt = now + KapaBlink.doubleGap }
    }

    /// Where the eyes go: to the pointer over Kapa, to a file being dragged
    /// near, sweeping while dictation is recognised, glancing about now and
    /// then at rest — and otherwise where the pose looks.
    private func followTheEyes(_ face: KapaFace, inputs: Inputs, dt: Double) {
        var target = face.look
        let size = Double(inputs.size)
        if let hover {
            target = KapaLook(
                yaw: clamp((Double(hover.x) - size / 2) / size * 1.3, 0.5),
                pitch: clamp((size / 2 - Double(hover.y)) / size + 0.08, 0.4)
            )
        } else if expression == .dropReady, let point = dragPoint(), frame != .zero {
            // Coucou's look: tanh of the distance, so a far file still pulls
            // the eyes and a near one does not throw them round the head.
            let across = Double(point.x - frame.midX)
            let up = Double(frame.midY - point.y)
            target = KapaLook(yaw: tanh(across / 120) * 0.55, pitch: tanh(up / 90) * 0.4)
        } else if expression == .thinking {
            target.yaw += sin(now * 2.6) * 0.16
        } else if [.rest, .focused, .curious, .stale, .paused].contains(expression) {
            if now >= nextWander {
                nextWander = now + .random(in: 2.5 ... 6)
                wander = .random(in: 0 ... 1) < 0.4
                    ? .ahead
                    : KapaLook(yaw: .random(in: -0.18 ... 0.18), pitch: .random(in: -0.06 ... 0.1))
            }
            target.yaw += wander.yaw
            target.pitch += wander.pitch
        }
        settledAt = target
        yaw = KapaMotion.approach(yaw, to: target.yaw, base: 0.0025, dt: dt)
        pitch = KapaMotion.approach(pitch, to: target.pitch, base: 0.0025, dt: dt)
    }

    private func moveTheBody(_ face: KapaFace, inputs: Inputs, dt: Double) {
        var targetTilt = face.tilt
        var loopSX = 1.0
        var loopSY = 1.0
        var loopDY = 0.0
        switch expression {
        case .music:
            let bob = KapaMotion.bob(at: now)
            loopDY = bob.dy
            loopSY = bob.sy
            targetTilt += bob.tilt
        case .listening:
            let level = min(max(inputs.level, 0), 1)
            loopSY = 1 + level * 0.08
            loopSX = 1 - level * 0.03
            loopDY = -level * 2.5
            targetTilt += level * 6
        case .dropReady:
            // Leaning towards the file, a little up on its toes.
            if let point = dragPoint(), frame != .zero {
                targetTilt += tanh(Double(point.x - frame.midX) / 120) * 7
            }
            loopSY = 1.04
        default:
            // At rest Kapa holds still between its blinks and glances, so the
            // timeline can rest with it; breathing would keep it drawing.
            break
        }
        bodyTarget = (targetTilt, loopSX, loopSY, loopDY)
        // The music's dip and sway are curves of their own; following them
        // would only blunt them.
        if expression == .music {
            tilt = targetTilt
            sy = loopSY
            dy = loopDY
            sx = 1
        } else {
            tilt = KapaMotion.approach(tilt, to: targetTilt, base: 0.0008, dt: dt)
            sx = KapaMotion.approach(sx, to: loopSX, base: 0.0008, dt: dt)
            sy = KapaMotion.approach(sy, to: loopSY, base: 0.0008, dt: dt)
            dy = KapaMotion.approach(dy, to: loopDY, base: 0.0008, dt: dt)
        }
    }

    private func moveTheMouth(inputs: Inputs, dt: Double) {
        var target = 0.0
        if gulpAt != nil {
            // The gulp has the mouth; the spring waits, shut.
            mouth = 0
            mouthVelocity = 0
            return
        }
        if expression == .dropReady {
            if let swallowed = lastSwallowAt, now - swallowed < KapaMotion.gulpLength + 1 {
                target = 0
            } else if let point = dragPoint(), frame != .zero {
                let distance = hypot(Double(point.x - frame.midX), Double(point.y - frame.midY))
                target = KapaMotion.appetite(distance: distance, reach: Double(inputs.size) * 3)
            } else {
                target = 0.5
            }
        } else if expression == .listening {
            target = min(max(inputs.level, 0), 1) * 0.35
        }
        mouthTarget = target
        let spring = KapaMotion.spring(mouth, velocity: mouthVelocity, to: target, dt: dt)
        mouth = max(0, spring.value)
        mouthVelocity = spring.velocity
    }

    /// The pointer arriving draws a blink and a nod; left resting there for
    /// a moment it pleases Kapa, at most every six seconds (Coucou's
    /// rest-to-love, research §1.4).
    private func noticeThePointer() {
        guard hover != nil else {
            hoverSince = nil
            return
        }
        guard let since = hoverSince else {
            hoverSince = now
            blinkAt = now
            reaction = (.nod, now)
            return
        }
        if now - since > 1.9, now - lastPleased > 6 {
            lastPleased = now
            pleasedUntil = now + 1.4
            emit(.heart, count: 3)
        }
    }

    private func emitAmbient() {
        guard now >= nextAmbient else { return }
        switch expression {
        case .music:
            nextAmbient = now + 1.3
            emit(.note, count: 1)
        case .worried:
            nextAmbient = now + 2.6
            emit(.sweat, count: 1)
        case .waiting:
            nextAmbient = now + 1.8
            emit(.sleep, count: 1)
        default:
            nextAmbient = now + 1
        }
    }

    private func emit(_ kind: Particle.Kind, count: Int) {
        for index in 0 ..< count {
            let (x, y): (Double, Double) = switch kind {
            case .note: (82, 26)
            case .heart: (.random(in: 30 ... 74), 22)
            case .sparkle: (.random(in: 20 ... 84), .random(in: 14 ... 40))
            case .sweat: (78, 40)
            case .sleep: (74, 22)
            }
            particles.append(Particle(
                kind: kind,
                born: now + Double(index) * 0.14,
                life: kind == .sparkle ? 0.7 : .random(in: 1.3 ... 1.8),
                x: x, y: y,
                drift: .random(in: -6 ... 6)
            ))
        }
    }

    private func clamp(_ value: Double, _ limit: Double) -> Double { min(max(value, -limit), limit) }

    // MARK: When to draw next

    private static let frame = 1.0 / 30

    /// The next moment worth drawing after `time`: the next frame while
    /// anything moves, else whatever is due next.
    func nextFrame(after time: Double) -> Double {
        if isMoving(at: time) { return time + Self.frame }
        var due = nextBlink
        if let second = secondBlinkAt { due = min(due, second) }
        if [.rest, .focused, .curious, .stale, .paused].contains(expression) { due = min(due, nextWander) }
        if [.worried, .waiting].contains(expression) { due = min(due, nextAmbient) }
        return max(time + Self.frame, due)
    }

    private func isMoving(at time: Double) -> Bool {
        guard moving, shown != nil else { return false }
        // Moving for as long as they last.
        if [.music, .listening, .thinking, .dropReady].contains(expression) { return true }
        if hover != nil || swapping || gulpAt != nil || !particles.isEmpty { return true }
        if time - blinkAt < KapaBlink.closing + KapaBlink.opening + Self.frame { return true }
        if time < pleasedUntil || time - boopAt < 0.8 || time - shakeAt < KapaMotion.shakeLength { return true }
        if let reaction, time - reaction.at < KapaMotion.duration(of: reaction.kind) + Self.frame { return true }
        // Still on its way to where it is going.
        let near = 0.002
        return abs(yaw - settledAt.yaw) > near || abs(pitch - settledAt.pitch) > near
            || abs(tilt - bodyTarget.tilt) > 0.05 || abs(sx - bodyTarget.sx) > near
            || abs(sy - bodyTarget.sy) > near || abs(dy - bodyTarget.dy) > 0.02
            || abs(mouth - mouthTarget) > 0.01 || abs(mouthVelocity) > 0.05
    }

    // MARK: Drawing

    func draw(in context: inout GraphicsContext, canvas: CGSize, size: CGFloat, outline: Color?) {
        guard let face = shown else { return }
        let scale = size / 100
        let boost: CGFloat = size < 32 ? 1.5 : 1

        // The sheet's square, centred in the canvas.
        context.translateBy(x: (canvas.width - size) / 2, y: (canvas.height - size) / 2)
        context.scaleBy(x: scale, y: scale)

        let gulp = gulpAt.flatMap { KapaMotion.gulp(elapsed: now - $0) }
        var kick = KapaMotion.Kick()
        for extra in [
            reaction.flatMap { KapaMotion.kick($0.kind, elapsed: now - $0.at) },
            KapaMotion.boop(elapsed: now - boopAt),
            KapaMotion.shake(elapsed: now - shakeAt),
            gulp?.kick,
        ].compactMap(\.self) {
            kick.sx *= extra.sx
            kick.sy *= extra.sy
            kick.dy += extra.dy
            kick.dx += extra.dx
        }
        let pleased = now < pleasedUntil || gulp?.pleased == true || now - boopAt < 0.7

        context.fill(KapaPaths.ellipse(cx: 50, cy: 91, rx: 38, ry: 2.6), with: .color(.black.opacity(0.5)))

        var body = context
        // Every squash and lean about the middle of the base, where Kapa sits.
        body.translateBy(x: 50 + kick.dx, y: 90 + dy + kick.dy)
        body.rotate(by: .degrees(-tilt))
        body.scaleBy(x: sx * kick.sx, y: sy * kick.sy)
        body.translateBy(x: -50, y: -90)

        if let outline {
            body.stroke(KapaPaths.body, with: .color(outline), lineWidth: 6)
        }
        body.fill(KapaPaths.body, with: .radialGradient(
            Gradient(stops: [
                .init(color: Color(kapaHex: 0xBDF5F8), location: 0),
                .init(color: Color(kapaHex: 0x5BDBE4), location: 0.42),
                .init(color: Color(kapaHex: 0x2FAFBD), location: 1),
            ]),
            center: CGPoint(x: 36, y: 30), startRadius: 0, endRadius: 85
        ))
        body.fill(KapaPaths.shine, with: .color(.white.opacity(0.22)))
        if face.blush || pleased {
            let cheek = Color(kapaHex: 0xFF8FA3).opacity(0.35)
            body.fill(KapaPaths.ellipse(cx: 33, cy: 70, rx: 4, ry: 2.2), with: .color(cheek))
            body.fill(KapaPaths.ellipse(cx: 71, cy: 70, rx: 4, ry: 2.2), with: .color(cheek))
        }
        if face.headphones {
            body.stroke(KapaPaths.headband, with: .color(Color(kapaHex: 0x2E3236)), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            body.fill(KapaPaths.earcups, with: .color(Color(kapaHex: 0x3B4146)))
        }

        let look = KapaLook(yaw: yaw, pitch: pitch)
        let lid = KapaMotion.lid(sinceBlink: now - blinkAt)
        let eyes: KapaFace.Eyes = pleased && KapaBlink.blinks(face.eyes) ? .happy : face.eyes
        for side in [-1.0, 1.0] {
            KapaPaths.drawEye(eyes, side: side, look: look, lid: lid, boost: boost, in: body)
        }

        let shift = KapaGaze.features(look: look)
        var features = body
        features.translateBy(x: shift.dx, y: shift.dy)
        if let brows = KapaPaths.brows(face.brows) {
            features.stroke(brows, with: .color(KapaPaths.ink), style: StrokeStyle(lineWidth: 2 * boost, lineCap: .round))
        }
        let open = max(mouth, gulp?.mouth ?? 0)
        if open > 0.06 {
            // An open mouth, as wide as appetite or a gulp has it.
            features.fill(
                KapaPaths.ellipse(cx: 52, cy: 72 + 1.5 * open, rx: 3 + 4 * open, ry: 2 + 7.5 * open),
                with: .color(KapaPaths.ink)
            )
        } else {
            let mouth = KapaPaths.mouth(face.mouth)
            if mouth.filled {
                features.fill(mouth.path, with: .color(KapaPaths.ink))
            } else {
                features.stroke(mouth.path, with: .color(KapaPaths.ink), style: StrokeStyle(lineWidth: 2 * boost, lineCap: .round, lineJoin: .round))
            }
        }

        // The file going in: from above the head into the mouth, shrinking.
        if let travelled = gulp?.file {
            var file = context
            file.translateBy(x: 16 + (52 - 16) * travelled, y: 12 + (72 - 12) * travelled)
            let shrink = 1 - 0.75 * travelled
            file.scaleBy(x: shrink, y: shrink)
            file.translateBy(x: -16, y: -12)
            KapaPaths.drawBadge(.file, boost: boost, in: file)
        }

        // Signs stay upright when Kapa leans, and keep away while it eats.
        if gulp == nil {
            KapaPaths.drawBadge(face.badge, boost: boost, in: context)
        }

        drawParticles(in: context, boost: boost)
    }

    private func drawParticles(in context: GraphicsContext, boost: CGFloat) {
        for particle in particles where now >= particle.born {
            let age = (now - particle.born) / particle.life
            let alpha = age < 0.2 ? age / 0.2 : 1 - (age - 0.2) / 0.8
            let rise = (now - particle.born) * (particle.kind == .sweat ? -14 : 22)
            var x = particle.x + particle.drift * age
            if particle.kind == .heart { x += sin((now - particle.born) * 6) * 2.5 }
            var layer = context
            layer.opacity = max(0, alpha)
            layer.translateBy(x: x, y: particle.y - rise)
            let grow = 1 + age * 0.4
            layer.scaleBy(x: grow, y: grow)
            switch particle.kind {
            case .note:
                layer.stroke(KapaPaths.noteStem, with: .color(Color(kapaHex: 0x51D4DE)), style: StrokeStyle(lineWidth: 1.8 * boost, lineCap: .round))
                layer.fill(KapaPaths.ellipse(cx: -1.7, cy: 0, rx: 2.3, ry: 2.3), with: .color(Color(kapaHex: 0x51D4DE)))
            case .heart:
                layer.fill(KapaPaths.heart, with: .color(Color(kapaHex: 0xFF5C7A)))
            case .sparkle:
                layer.fill(KapaPaths.sparkle(radius: 5), with: .color(Color(kapaHex: 0xF2B35D)))
            case .sweat:
                layer.fill(KapaPaths.drop, with: .color(Color(kapaHex: 0x9BE7F0)))
            case .sleep:
                layer.fill(KapaPaths.sleepZ, with: .color(Color(kapaHex: 0xC9D1D4)))
            }
        }
    }
}

// MARK: - The sheet's shapes

/// Every shape in the sheet's 100-unit square, y down, as drawn in Paper.
enum KapaPaths {
    static let ink = Color(kapaHex: 0x102C35)

    /// The bell: a flat base, the curled tip at the top right.
    static let body = Path { path in
        path.move(to: CGPoint(x: 14, y: 90))
        path.addCurve(to: CGPoint(x: 8, y: 73), control1: CGPoint(x: 5, y: 90), control2: CGPoint(x: 3, y: 82))
        path.addCurve(to: CGPoint(x: 31, y: 27), control1: CGPoint(x: 15, y: 58), control2: CGPoint(x: 17, y: 39))
        path.addCurve(to: CGPoint(x: 55, y: 18), control1: CGPoint(x: 39, y: 20), control2: CGPoint(x: 47, y: 17))
        path.addCurve(to: CGPoint(x: 67, y: 8), control1: CGPoint(x: 59, y: 13), control2: CGPoint(x: 62, y: 9))
        path.addCurve(to: CGPoint(x: 70, y: 22), control1: CGPoint(x: 72, y: 9), control2: CGPoint(x: 72, y: 16))
        path.addCurve(to: CGPoint(x: 91, y: 66), control1: CGPoint(x: 80, y: 31), control2: CGPoint(x: 85, y: 46))
        path.addCurve(to: CGPoint(x: 86, y: 90), control1: CGPoint(x: 94, y: 76), control2: CGPoint(x: 96, y: 90))
        path.closeSubpath()
    }

    static let shine = Path(ellipseIn: CGRect(x: 26, y: 34, width: 16, height: 8))
        .applying(CGAffineTransform(translationX: 34, y: 38).rotated(by: -35 * .pi / 180).translatedBy(x: -34, y: -38))

    static let headband = Path { path in
        path.move(to: CGPoint(x: 17, y: 56))
        path.addCurve(to: CGPoint(x: 87, y: 56), control1: CGPoint(x: 15, y: 22), control2: CGPoint(x: 86, y: 18))
    }

    static let earcups = Path { path in
        path.addRoundedRect(in: CGRect(x: 10, y: 48, width: 12, height: 20), cornerSize: CGSize(width: 5, height: 5))
        path.addRoundedRect(in: CGRect(x: 82, y: 48, width: 12, height: 20), cornerSize: CGSize(width: 5, height: 5))
    }

    static let noteStem = Path { path in
        path.move(to: CGPoint(x: 0, y: 0)); path.addLine(to: CGPoint(x: 0, y: -11))
        path.addLine(to: CGPoint(x: 6, y: -12.5)); path.addLine(to: CGPoint(x: 6, y: -8))
    }

    static let heart = Path { path in
        path.move(to: CGPoint(x: 0, y: 4))
        path.addCurve(to: CGPoint(x: 0, y: -2), control1: CGPoint(x: -7, y: -1), control2: CGPoint(x: -3, y: -6))
        path.addCurve(to: CGPoint(x: 0, y: 4), control1: CGPoint(x: 3, y: -6), control2: CGPoint(x: 7, y: -1))
    }

    static let drop = Path { path in
        path.move(to: CGPoint(x: 0, y: -4))
        path.addQuadCurve(to: CGPoint(x: 0, y: 3), control: CGPoint(x: 4, y: 1.5))
        path.addQuadCurve(to: CGPoint(x: 0, y: -4), control: CGPoint(x: -4, y: 1.5))
    }

    /// A "z", drawn rather than typed, so it scales with the rest.
    static let sleepZ = Path { path in
        path.addLines([
            CGPoint(x: -3, y: -3), CGPoint(x: 3, y: -3), CGPoint(x: 3, y: -1.8),
            CGPoint(x: -1, y: 1.8), CGPoint(x: 3, y: 1.8), CGPoint(x: 3, y: 3),
            CGPoint(x: -3, y: 3), CGPoint(x: -3, y: 1.8), CGPoint(x: 1, y: -1.8), CGPoint(x: -3, y: -1.8),
        ])
        path.closeSubpath()
    }

    static func sparkle(radius r: CGFloat) -> Path {
        Path { path in
            path.addLines([
                CGPoint(x: 0, y: -r), CGPoint(x: r * 0.25, y: -r * 0.25), CGPoint(x: r, y: 0), CGPoint(x: r * 0.25, y: r * 0.25),
                CGPoint(x: 0, y: r), CGPoint(x: -r * 0.25, y: r * 0.25), CGPoint(x: -r, y: 0), CGPoint(x: -r * 0.25, y: -r * 0.25),
            ])
            path.closeSubpath()
        }
    }

    static func ellipse(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
    }

    static func lines(_ points: [(CGFloat, CGFloat, CGFloat, CGFloat)]) -> Path {
        Path { path in
            for (x1, y1, x2, y2) in points {
                path.move(to: CGPoint(x: x1, y: y1)); path.addLine(to: CGPoint(x: x2, y: y2))
            }
        }
    }

    // MARK: Eyes

    /// One eye: placed and narrowed by the gaze, shut by `lid` (1 open).
    static func drawEye(_ eyes: KapaFace.Eyes, side: Double, look: KapaLook, lid: Double, boost: CGFloat, in context: GraphicsContext) {
        let gaze = KapaGaze.eye(side: side, look: look)
        guard !gaze.isHidden else { return }
        let raise: CGFloat = eyes == .wide ? -2 : (eyes == .uneven && side > 0 ? 1 : 0)
        // A mini Kapa is read by its eyes alone, so there they are a fifth
        // larger — Coucou draws its minis' at nearly twice the size.
        let enlarge: CGFloat = boost > 1 ? 1.2 : 1
        var eye = context
        eye.translateBy(x: gaze.x, y: gaze.y + raise)
        eye.scaleBy(x: gaze.scaleX * enlarge, y: gaze.scaleY * enlarge * max(lid, 0.08))

        func oval(_ rx: CGFloat, _ ry: CGFloat, dy: CGFloat = 0, dx: CGFloat = 0) -> Path {
            Path(ellipseIn: CGRect(x: dx - rx, y: dy - ry, width: rx * 2, height: ry * 2))
        }
        func fill(_ path: Path) { eye.fill(path, with: .color(ink)) }
        func light(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) { eye.fill(oval(r, r, dy: y, dx: x), with: .color(.white)) }
        func arc(_ from: CGPoint, _ control: CGPoint, _ to: CGPoint) {
            eye.stroke(Path { $0.move(to: from); $0.addQuadCurve(to: to, control: control) },
                       with: .color(ink), style: StrokeStyle(lineWidth: 2.6 * boost, lineCap: .round))
        }

        switch eyes {
        case .open:
            fill(oval(5, 6.5)); light(1.6, -2.6, 1.6)
        case .wide:
            fill(oval(5.6, 7.4)); light(1, -3.8, 1.8)
        case .happy:
            arc(CGPoint(x: -5.5, y: 1), CGPoint(x: 0, y: -5.5), CGPoint(x: 5.5, y: 1))
        case .closed:
            arc(CGPoint(x: -5.5, y: 0), CGPoint(x: 0, y: 5), CGPoint(x: 5.5, y: 0))
        case .lidded:
            fill(Path { path in
                path.move(to: CGPoint(x: -5, y: 0))
                path.addLine(to: CGPoint(x: 5, y: 0))
                path.addArc(center: .zero, radius: 5, startAngle: .zero, endAngle: .degrees(180), clockwise: false)
                path.closeSubpath()
            })
            eye.stroke(lines([(-5.5, -0.5, 5.5, -0.5)]), with: .color(Color(kapaHex: 0x1E5560)), style: StrokeStyle(lineWidth: 1.6 * boost, lineCap: .round))
        case .narrowed:
            fill(oval(5, 3.4, dy: 1)); light(1.8, 0, 1.2)
        case .uneven:
            if side < 0 {
                fill(oval(5, 6.5)); light(1.5, -2.4, 1.5)
            } else {
                fill(oval(4.2, 5)); light(1.2, -1.8, 1.2)
            }
        }
    }

    // MARK: Brows and mouths

    static func brows(_ brows: KapaFace.Brows) -> Path? {
        switch brows {
        case .none:
            nil
        case .worried:
            lines([(35, 52, 46, 49), (58, 49, 69, 52)])
        case .puzzled:
            Path { path in
                path.move(to: CGPoint(x: 35, y: 50.5))
                path.addQuadCurve(to: CGPoint(x: 46.5, y: 48.5), control: CGPoint(x: 40.5, y: 45.5))
                path.move(to: CGPoint(x: 58.5, y: 53.5)); path.addLine(to: CGPoint(x: 68, y: 53.5))
            }
        }
    }

    static func mouth(_ mouth: KapaFace.Mouth) -> (path: Path, filled: Bool) {
        func curve(_ from: CGPoint, _ control: CGPoint, _ to: CGPoint) -> Path {
            Path { $0.move(to: from); $0.addQuadCurve(to: to, control: control) }
        }
        switch mouth {
        case .smile: return (curve(CGPoint(x: 48, y: 70), CGPoint(x: 52, y: 73.5), CGPoint(x: 56, y: 70)), false)
        case .small: return (curve(CGPoint(x: 49, y: 70), CGPoint(x: 52, y: 72), CGPoint(x: 55, y: 70)), false)
        case .line: return (lines([(49, 71, 55, 71)]), false)
        case .open: return (ellipse(cx: 52, cy: 73, rx: 4.6, ry: 5.6), true)
        case .grin:
            return (Path { path in
                path.move(to: CGPoint(x: 47, y: 68))
                path.addQuadCurve(to: CGPoint(x: 57, y: 68), control: CGPoint(x: 52, y: 76))
                path.closeSubpath()
            }, true)
        case .worried: return (curve(CGPoint(x: 48, y: 72), CGPoint(x: 52, y: 69.5), CGPoint(x: 56, y: 72)), false)
        case .wobble:
            return (Path { path in
                path.move(to: CGPoint(x: 47, y: 71))
                path.addQuadCurve(to: CGPoint(x: 52, y: 71), control: CGPoint(x: 49.5, y: 69))
                path.addQuadCurve(to: CGPoint(x: 57, y: 71), control: CGPoint(x: 54.5, y: 73))
            }, false)
        }
    }

    // MARK: Signs

    /// The signs, top right of the square where the tip leaves room; the
    /// file top left, where a dropped one comes from.
    static func drawBadge(_ badge: KapaFace.Badge, boost: CGFloat, in context: GraphicsContext) {
        func stroke(_ path: Path, _ colour: Color, _ width: CGFloat, dash: [CGFloat] = []) {
            context.stroke(path, with: .color(colour), style: StrokeStyle(lineWidth: width * boost, lineCap: .round, lineJoin: .round, dash: dash))
        }
        let disc = ellipse(cx: 86, cy: 16, rx: 8.5, ry: 8.5)
        let amber = Color(kapaHex: 0xF2B35D)
        switch badge {
        case .none:
            break
        case .check:
            context.fill(disc, with: .color(Color(kapaHex: 0x34C759)))
            stroke(Path { $0.addLines([CGPoint(x: 81.8, y: 16.2), CGPoint(x: 85, y: 19.4), CGPoint(x: 90.5, y: 13)]) }, .white, 2.1)
        case .alert:
            context.fill(disc, with: .color(amber))
            stroke(lines([(86, 11.5, 86, 17)]), Color(kapaHex: 0x2A1B05), 2.2)
            context.fill(ellipse(cx: 86, cy: 20.6, rx: 1.3, ry: 1.3), with: .color(Color(kapaHex: 0x2A1B05)))
        case .clock:
            stroke(disc, amber, 2.2)
            stroke(Path { $0.addLines([CGPoint(x: 86, y: 11.5), CGPoint(x: 86, y: 16), CGPoint(x: 89.5, y: 18)]) }, amber, 2.2)
        case .dashedClock:
            stroke(disc, Color(kapaHex: 0x9AA3A8), 1.6, dash: [2.6, 2.2])
            stroke(Path { $0.addLines([CGPoint(x: 86, y: 11.5), CGPoint(x: 86, y: 16), CGPoint(x: 89, y: 18)]) }, Color(kapaHex: 0xC9D1D4), 1.6)
        case .cross:
            context.fill(disc, with: .color(Color(kapaHex: 0xFF453A)))
            stroke(lines([(82.8, 12.8, 89.2, 19.2), (89.2, 12.8, 82.8, 19.2)]), .white, 2)
        case .clipboard:
            let board = Path(roundedRect: CGRect(x: 78, y: 8, width: 17, height: 21), cornerRadius: 3)
            context.fill(board, with: .color(Color(kapaHex: 0x2A2E32)))
            stroke(board, amber, 1.4)
            context.fill(Path(roundedRect: CGRect(x: 82.5, y: 5.5, width: 8, height: 4.5), cornerRadius: 1.5), with: .color(amber))
            stroke(lines([(81.5, 16, 91.5, 16), (81.5, 20, 91.5, 20), (81.5, 24, 87, 24)]), Color(kapaHex: 0xC9D1D4), 1.2)
        case .file:
            context.fill(
                Path { $0.addLines([CGPoint(x: 8, y: 2), CGPoint(x: 19, y: 2), CGPoint(x: 24, y: 7), CGPoint(x: 24, y: 22), CGPoint(x: 8, y: 22)]); $0.closeSubpath() },
                with: .color(Color(kapaHex: 0xF2F4F5))
            )
            context.fill(
                Path { $0.addLines([CGPoint(x: 19, y: 2), CGPoint(x: 19, y: 7), CGPoint(x: 24, y: 7)]); $0.closeSubpath() },
                with: .color(Color(kapaHex: 0xC9CFD2))
            )
            stroke(lines([(11, 11, 21, 11), (11, 14.5, 21, 14.5), (11, 18, 17, 18)]), Color(kapaHex: 0x9AA3A8), 1.2)
        case .note:
            var note = context
            note.translateBy(x: 93, y: 17)
            note.stroke(noteStem, with: .color(Color(kapaHex: 0x51D4DE)), style: StrokeStyle(lineWidth: 1.8 * boost, lineCap: .round))
            note.fill(ellipse(cx: -1.7, cy: 0.5, rx: 2.3, ry: 2.3), with: .color(Color(kapaHex: 0x51D4DE)))
        case .unplugged:
            context.fill(ellipse(cx: 86, cy: 16, rx: 9, ry: 9), with: .color(Color(kapaHex: 0x3A3F44)))
            stroke(lines([(80.5, 19, 83.5, 16), (88.5, 16, 91.5, 13), (82, 12, 90, 20)]), Color(kapaHex: 0xC9D1D4), 2)
        case .sparkle:
            var star = context
            star.translateBy(x: 88, y: 15)
            star.fill(sparkle(radius: 9), with: .color(amber))
        case .pause:
            stroke(disc, Color(kapaHex: 0x51D4DE), 1.8)
            stroke(lines([(83.5, 12.5, 83.5, 19.5), (88.5, 12.5, 88.5, 19.5)]), Color(kapaHex: 0x51D4DE), 2.2)
        }
    }
}

extension Color {
    /// One of the sheet's colours, as Paper writes it.
    init(kapaHex hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
