import AppKit
import CapacityNotchCore
import QuartzCore
import SwiftUI

// MARK: - The row under the compact strip

/// The Teleprompter Row (CONTEXT.md), as drawn in Paper "Notch — Compact —
/// Teleprompter running / paused": three lines under the strip, the current
/// one on top and nearest the camera, the next two quieter; on the left, a
/// column that stays put while the Script moves — beside the current line
/// the action a click would take, pause while running and play otherwise,
/// and under it Stop.
struct TeleprompterRow: View {
    @ObservedObject var teleprompter: TeleprompterController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let size = teleprompter.textSize
        ScriptScroll(
            lines: teleprompter.lines,
            size: size,
            playback: teleprompter.playback,
            reduceMotion: reduceMotion
        )
        .frame(width: TeleprompterLayout.rowWidth, height: TeleprompterLayout.textAreaHeight(size))
        .overlay(alignment: .topLeading) {
            VStack(spacing: TeleprompterLayout.lineGap) {
                Button { teleprompter.toggle() } label: {
                    Image(systemName: teleprompter.playback.state.actionSymbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: TeleprompterLayout.controlsWidth, height: TeleprompterLayout.lineHeight(size))
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(teleprompter.playback.state == .running ? L("Pause") : L("Start"))
                Button { teleprompter.stop() } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(SurfaceType.red)
                        .frame(width: TeleprompterLayout.controlsWidth, height: TeleprompterLayout.lineHeight(size))
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(L("Stop"))
            }
            .buttonStyle(.plain)
            .padding(.top, TeleprompterLayout.topInset)
            .padding(.leading, 18)
        }
        .padding(.top, TeleprompterLayout.stripGap)
        .contentShape(Rectangle())
        .onTapGesture { teleprompter.toggle() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(teleprompter.playback.state.spoken)
    }
}

/// The Script's lines, moved by Core Animation rather than redrawn by SwiftUI:
/// a steady scroll is one animation the render server runs, and the
/// application wakes only to add the lines coming into view.
private struct ScriptScroll: NSViewRepresentable {
    let lines: [String]
    let size: TeleprompterTextSize
    let playback: TeleprompterPlayback
    let reduceMotion: Bool

    func makeNSView(context: Context) -> ScriptScrollView { ScriptScrollView() }

    func updateNSView(_ view: ScriptScrollView, context: Context) {
        view.update(lines: lines, size: size, playback: playback, reduceMotion: reduceMotion)
    }
}

final class ScriptScrollView: NSView {
    private let content = CALayer()
    private let fade = CAGradientLayer()
    private var lineLayers: [Int: CATextLayer] = [:]
    private var lines: [String] = []
    private var size: TeleprompterTextSize = .medium
    private var playback = TeleprompterPlayback(wordCount: 0, lineCount: 0)
    private var reduceMotion = false
    private var refresh: Timer?

    override var isFlipped: Bool { true }

    /// A click on the Script belongs to the row around it, which pauses and
    /// resumes; this view only draws.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// `CALayer.render(in:)`, which the pictures are taken with, leaves masks
    /// out; drawn for a picture, each line carries its own fade instead.
    nonisolated(unsafe) static var drawnForPictures = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Lines counted down from the top, as the view is.
        layer?.isGeometryFlipped = true
        layer?.masksToBounds = true
        content.anchorPoint = .zero
        layer?.addSublayer(content)
        if !Self.drawnForPictures { layer?.mask = fade }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        layoutFade()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        lineLayers.values.forEach { $0.contentsScale = scale }
    }

    func update(lines: [String], size: TeleprompterTextSize, playback: TeleprompterPlayback, reduceMotion: Bool) {
        if lines != self.lines || size != self.size {
            lineLayers.values.forEach { $0.removeFromSuperlayer() }
            lineLayers = [:]
            self.lines = lines
            self.size = size
            layoutFade()
        }
        let changed = playback != self.playback || reduceMotion != self.reduceMotion
        self.playback = playback
        self.reduceMotion = reduceMotion
        if changed || lineLayers.isEmpty { placeScript() }
    }

    /// Puts the Script where the playback says it is, and — running — sets it
    /// moving to the last line at the playback's speed.
    private func placeScript() {
        refresh?.invalidate()
        refresh = nil
        let now = Date()
        let position = playback.position(at: now)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.removeAllAnimations()
        content.bounds = CGRect(x: 0, y: 0, width: TeleprompterLayout.rowWidth, height: CGFloat(max(lines.count, 1)) * pitch)
        content.position = CGPoint(x: 0, y: offset(reduceMotion ? position.rounded(.down) : position))
        showLines(around: position)
        CATransaction.commit()

        guard playback.state == .running, let endsAt = playback.endsAt, !Self.drawnForPictures else { return }

        let remaining = playback.remainingSeconds(at: now)
        let hold = max(endsAt.timeIntervalSince(now) - remaining, 0)
        if !reduceMotion, remaining > 0 {
            let last = Double(max(lines.count - 1, 0))
            let motion = CABasicAnimation(keyPath: "position.y")
            motion.fromValue = offset(position)
            motion.toValue = offset(last)
            motion.beginTime = CACurrentMediaTime() + hold
            motion.duration = remaining
            motion.fillMode = .backwards
            motion.timingFunction = CAMediaTimingFunction(name: .linear)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            content.position.y = offset(last)
            content.add(motion, forKey: "scroll")
            CATransaction.commit()
        }

        // Lines coming into view are made a little before they arrive; under
        // Reduce Motion the same beat moves the Script a line at a time.
        let timer = Timer(timeInterval: reduceMotion ? 0.25 : 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refresh = timer
    }

    private func tick() {
        let position = playback.position(at: Date())
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if reduceMotion { content.position.y = offset(position.rounded(.down)) }
        showLines(around: position)
        CATransaction.commit()
        if playback.state != .running || position >= Double(lines.count - 1) {
            refresh?.invalidate()
            refresh = nil
        }
    }

    /// The lines in view, one before for the one leaving and a few after for
    /// those arriving; the rest are let go, so a long Script costs no more
    /// than a short one.
    private func showLines(around position: Double) {
        guard !lines.isEmpty else { return }
        let first = max(Int(position.rounded(.down)) - 1, 0)
        let last = min(Int(position.rounded(.down)) + TeleprompterLayout.visibleLines + 3, lines.count - 1)
        let wanted = Set(first ... last)

        for (index, layer) in lineLayers where !wanted.contains(index) {
            layer.removeFromSuperlayer()
            lineLayers[index] = nil
        }
        for index in wanted where lineLayers[index] == nil {
            let layer = CATextLayer()
            layer.string = NSAttributedString(string: lines[index], attributes: TeleprompterLayout.attributes(size))
            layer.contentsScale = scale
            layer.isWrapped = false
            layer.truncationMode = .end
            layer.frame = CGRect(
                x: TeleprompterLayout.textInset,
                y: CGFloat(index) * pitch,
                width: TeleprompterLayout.textWidth,
                height: TeleprompterLayout.lineHeight(size)
            )
            if Self.drawnForPictures {
                let row = CGFloat(index) - CGFloat(position.rounded(.down))
                layer.opacity = row <= 0 ? 1 : row == 1 ? Float(0x8C) / 255 : Float(0x40) / 255
            }
            content.addSublayer(layer)
            lineLayers[index] = layer
        }
    }

    /// Three bands, one per line in view: the current line full white, the
    /// next at 55%, the one after at 25% (the mockup's #FFF, #FFFFFF8C,
    /// #FFFFFF40). Each changes to the next within the two points between
    /// lines, so a line at rest is one colour and a moving one passes from
    /// band to band.
    private func layoutFade() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = bounds
        let height = max(bounds.height, 1)
        let lineHeight = TeleprompterLayout.lineHeight(size)
        let bottom = { (line: Int) in (TeleprompterLayout.topInset + CGFloat(line) * self.pitch + lineHeight) / height }
        let top = { (line: Int) in (TeleprompterLayout.topInset + CGFloat(line) * self.pitch) / height }
        fade.colors = [1, 1, 0x8C / 255.0, 0x8C / 255.0, 0x40 / 255.0, 0x40 / 255.0].map {
            NSColor.white.withAlphaComponent($0).cgColor
        }
        fade.locations = [0, bottom(0), top(1), bottom(1), top(2), 1].map { NSNumber(value: Double($0)) }
        fade.startPoint = CGPoint(x: 0.5, y: 0)
        fade.endPoint = CGPoint(x: 0.5, y: 1)
        CATransaction.commit()
    }

    private var pitch: CGFloat { TeleprompterLayout.pitch(size) }
    private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    private func offset(_ position: Double) -> CGFloat {
        TeleprompterLayout.topInset - CGFloat(position) * pitch
    }
}

private extension TeleprompterPlayback.State {
    /// What a click would do, drawn as it is in Music: pause while it runs,
    /// play otherwise.
    var actionSymbol: String { self == .running ? "pause.fill" : "play.fill" }

    var spoken: String {
        switch self {
        case .running: L("Teleprompter, running")
        case .paused: L("Teleprompter, paused")
        case .finished: L("Teleprompter, finished")
        case .stopped: L("Teleprompter, stopped")
        }
    }
}

// MARK: - The expanded surface's page

/// Paper "Notch — Expanded — Teleprompter": the current line and the next, the
/// progress to drag, the time read and left, and the controls — pause or play,
/// slower and faster, Paste, Edit Script.
struct TeleprompterPage: View {
    @ObservedObject var teleprompter: TeleprompterController
    /// Whether the page can be seen, so the clock ticks only then.
    var isVisible = true

    var body: some View {
        let running = teleprompter.playback.state == .running
        TimelineView(.periodic(from: .now, by: running && isVisible ? 0.25 : 3600)) { context in
            content(at: context.date)
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .foregroundStyle(.white)
    }

    private func content(at now: Date) -> some View {
        let playback = teleprompter.playback
        let size = teleprompter.textSize
        let current = min(Int(playback.position(at: now).rounded(.down)), max(teleprompter.lines.count - 1, 0))
        let font = SurfaceType.geist(size.points, .medium)
        let lineHeight = TeleprompterLayout.lineHeight(size)

        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: TeleprompterLayout.lineGap) {
                if teleprompter.lines.isEmpty {
                    Text(L("Paste a Script, or write one in Settings."))
                        .font(font)
                        .foregroundStyle(SurfaceType.captionColour)
                        .frame(height: lineHeight)
                } else {
                    previewLine(current, font: font, size: size, opacity: 1)
                    previewLine(current + 1, font: font, size: size, opacity: 0x8C / 255)
                    previewLine(current + 2, font: font, size: size, opacity: 0x40 / 255)
                }
            }
            .frame(
                height: CGFloat(TeleprompterLayout.visibleLines) * lineHeight
                    + CGFloat(TeleprompterLayout.visibleLines - 1) * TeleprompterLayout.lineGap,
                alignment: .top
            )
            // VoiceOver hears the Teleprompter's state, never the Script.
            .accessibilityHidden(true)

            ScriptProgress(teleprompter: teleprompter, now: now)

            HStack(spacing: 8) {
                Button { teleprompter.toggle() } label: {
                    Image(systemName: playback.state.actionSymbol)
                        .font(.system(size: 14, weight: .semibold))
                        .frame(height: 18)
                        .contentShape(Rectangle())
                }
                .disabled(teleprompter.lines.isEmpty)
                .accessibilityLabel(playback.state == .running ? L("Pause") : L("Start"))

                Button { teleprompter.stop() } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(SurfaceType.red)
                        .frame(height: 18)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(L("Stop"))

                HStack(spacing: 10) {
                    Button { teleprompter.slower() } label: {
                        Image(systemName: "minus").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(SurfaceType.captionColour)
                    }
                    .accessibilityLabel(L("Slower"))

                    Text(String(format: "%.2fx", playback.multiplier))
                        .font(SurfaceType.geist(13, .semibold))
                        .monospacedDigit()
                        .accessibilityLabel(L("Speed"))
                        .accessibilityValue(L("%.2f times", playback.multiplier))

                    Button { teleprompter.faster() } label: {
                        Image(systemName: "plus").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(SurfaceType.captionColour)
                    }
                    .accessibilityLabel(L("Faster"))
                }

                Spacer()

                HStack(spacing: 16) {
                    Button(L("Paste")) { teleprompter.pasteFromClipboard() }
                    Button(L("Edit Script")) { teleprompter.openSettings() }
                }
                .font(SurfaceType.geist(13, .medium))
                .foregroundStyle(SurfaceType.captionColour)
            }
            .buttonStyle(.plain)
            .frame(height: 18)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(playback.state.spoken)
    }

    private func previewLine(_ index: Int, font: Font, size: TeleprompterTextSize, opacity: Double) -> some View {
        Text(teleprompter.lines.indices.contains(index) ? teleprompter.lines[index] : " ")
            .font(font)
            .kerning(TeleprompterLayout.kern(size))
            .foregroundStyle(Color.white.opacity(opacity))
            .lineLimit(1)
            .frame(height: TeleprompterLayout.lineHeight(size))
    }
}

/// How far through the Script, drawn and dragged like a track's position.
private struct ScriptProgress: View {
    @ObservedObject var teleprompter: TeleprompterController
    let now: Date

    private let _dragged = State<Double?>(initialValue: nil)
    private var dragged: Double? {
        get { _dragged.wrappedValue }
        nonmutating set { _dragged.wrappedValue = newValue }
    }

    var body: some View {
        let playback = teleprompter.playback
        let fraction = dragged ?? playback.progress(at: now)

        VStack(spacing: 7) {
            Capsule()
                .fill(MusicType.track)
                .frame(height: 4)
                .overlay {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Color.clear
                            // Four points at the start, as drawn: where the
                            // Script is, even before it moves.
                            Capsule()
                                .fill(.white)
                                .frame(width: max(proxy.size.width * min(max(fraction, 0), 1), 4))
                        }
                        .contentShape(Rectangle().inset(by: -6))
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    dragged = min(max(value.location.x / proxy.size.width, 0), 1)
                                }
                                .onEnded { _ in
                                    if let dragged { teleprompter.seek(toFraction: dragged) }
                                    dragged = nil
                                }
                        )
                    }
                }

            HStack {
                Text(Self.clock(playback.elapsedSeconds(at: now)))
                Spacer()
                Text(Self.clock(playback.durationSeconds))
            }
            .font(MusicType.time)
            .foregroundStyle(MusicType.secondary)
            .frame(height: 14)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Progress through the Script"))
        .accessibilityValue(L("%d percent", Int((fraction * 100).rounded())))
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let whole = Int(max(seconds, 0).rounded(.down))
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }
}
