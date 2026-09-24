import AppKit
import CapacityNotchCore
import SwiftUI

/// The Music Module as the author drew it: a row under the compact strip
/// (Paper, "Notch — Compact — Playing") and a page of the expanded surface
/// ("Notch — Expanded — Playing"). Every size is the drawing's own.
enum MusicType {
    static let title = Font.system(size: 15, weight: .medium)
    static let artist = Font.system(size: 11, weight: .regular)
    static let time = Font.system(size: 11, weight: .regular)
    static let secondary = SurfaceType.captionColour
    static let track = SurfaceType.trackColour

    /// Six points under the strip, the artwork's 34, and 14 to the rounded
    /// edge: the closed surface is 92 with a track, as drawn.
    static let rowHeight: CGFloat = 54
    static let rowArtwork: CGFloat = 34
    static let pageArtwork: CGFloat = 120
}

// MARK: - Pieces

/// The track's artwork, or — when the source has sent none — the icon of the
/// application playing it, small, on a quiet ground rather than stretched.
struct MusicArtwork: View {
    let track: NowPlaying
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        Group {
            if let data = track.artwork, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.08)
                    if let icon = Self.icon(of: track.player) {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: size * 0.6, height: size * 0.6)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .accessibilityHidden(true)
    }

    private static func icon(of bundleIdentifier: String?) -> NSImage? {
        guard
            let bundleIdentifier,
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// Seven bars, as drawn. Decorative: while the track plays each one moves to
/// a new height of its own every 0.3 seconds, so the bars never fall into a
/// rhythm; paused they sink to four-point dashes ("Notch — Compact — Pause"),
/// and under Reduce Motion they hold still. No audio is captured.
///
/// Drawn with Core Animation, not SwiftUI. Animated in SwiftUI — a timeline
/// redrawing the bars — the surface cost a fifth of a core, measured; here the
/// application wakes three times a second to choose heights, the render server
/// moves the bars, and at 24 frames a second rather than 120.
struct EqualizerBars: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isPlaying: Bool
    /// The tallest a bar can stand: 30 under the strip, 34 on the music page.
    var height: CGFloat = 34

    var body: some View {
        EqualizerLayers(moving: isPlaying && !reduceMotion, resting: !isPlaying, height: height)
            .frame(width: EqualizerView.width, height: height)
            .accessibilityHidden(true)
    }
}

private struct EqualizerLayers: NSViewRepresentable {
    let moving: Bool
    let resting: Bool
    let height: CGFloat

    func makeNSView(context: Context) -> EqualizerView {
        EqualizerView(height: height)
    }

    func updateNSView(_ view: EqualizerView, context: Context) {
        view.update(moving: moving, resting: resting)
    }
}

final class EqualizerView: NSView {
    static let count = 7
    static let width: CGFloat = CGFloat(count) * 2 + CGFloat(count - 1) * 3
    /// A paused bar: a four-point dash.
    private static let rest: CGFloat = 4
    private static let beat: TimeInterval = 0.3

    private let height: CGFloat
    private var bars: [CALayer] = []
    private var timer: Timer?
    private var moving = false
    private var resting: Bool?

    init(height: CGFloat) {
        self.height = height
        super.init(frame: .zero)
        wantsLayer = true
        for index in 0 ..< Self.count {
            // Full height, scaled down to the one shown, so every bar can
            // reach the top and each moves by scale alone.
            let bar = CALayer()
            bar.backgroundColor = NSColor.white.withAlphaComponent(0x8C / 255).cgColor
            bar.cornerRadius = 1
            bar.frame = CGRect(x: CGFloat(index) * 5, y: 0, width: 2, height: height)
            bar.transform = CATransform3DMakeScale(1, Self.rest / height, 1)
            layer?.addSublayer(bar)
            bars.append(bar)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(moving: Bool, resting: Bool) {
        if moving != self.moving {
            self.moving = moving
            if moving { start() } else { stop() }
        }
        if resting != self.resting {
            self.resting = resting
            // Paused, the bars sink to dashes; playing under Reduce Motion
            // they stand still at heights of their own.
            if resting {
                for bar in bars { move(bar, to: Self.rest / height) }
            } else if !moving {
                step()
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() } else if moving { start() }
    }

    private func start() {
        guard timer == nil, window != nil else { return }
        step()
        let timer = Timer(timeInterval: Self.beat, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// A new height for every bar, from a third of the way up to the top —
    /// the drawing's shortest playing bar stands 10 of 30.
    private func step() {
        for bar in bars { move(bar, to: .random(in: 0.3...1)) }
    }

    /// From wherever the bar is on screen now, so a new height taken mid-way
    /// continues the motion instead of jumping back to where the last one began.
    private func move(_ bar: CALayer, to scale: CGFloat) {
        let current = (bar.presentation()?.value(forKeyPath: "transform.scale.y") as? CGFloat)
            ?? (bar.value(forKeyPath: "transform.scale.y") as? CGFloat)
            ?? 1
        let animation = CABasicAnimation(keyPath: "transform.scale.y")
        animation.fromValue = current
        animation.toValue = scale
        animation.duration = Self.beat
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 24, preferred: 24)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bar.transform = CATransform3DMakeScale(1, scale, 1)
        CATransaction.commit()
        bar.add(animation, forKey: "height")
    }
}

struct MusicControls: View {
    let isPlaying: Bool
    let small: CGFloat
    let large: CGFloat
    let send: (MusicCommand) -> Void

    var body: some View {
        HStack(spacing: 8) {
            control("backward.fill", size: small, label: "Previous track") { send(.previous) }
            control(isPlaying ? "pause.fill" : "play.fill", size: large, label: isPlaying ? "Pause" : "Play") {
                send(.togglePlayPause)
            }
            control("forward.fill", size: small, label: "Next track") { send(.next) }
        }
        .foregroundStyle(.white)
    }

    private func control(
        _ symbol: String,
        size: CGFloat,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct TrackText: View {
    let track: NowPlaying

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(track.title)
                .font(MusicType.title)
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(height: 18)
            if let artist = track.artist {
                Text(artist)
                    .font(MusicType.artist)
                    .foregroundStyle(MusicType.secondary)
                    .lineLimit(1)
                    .frame(height: 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - The row under the compact strip

struct CompactMusicRow: View {
    let track: NowPlaying
    let width: CGFloat
    let send: (MusicCommand) -> Void

    var body: some View {
        HStack(spacing: 20) {
            HStack(spacing: 8) {
                MusicArtwork(track: track, size: MusicType.rowArtwork, radius: 10)
                TrackText(track: track)
            }
            HStack(spacing: 20) {
                MusicControls(isPlaying: track.isPlaying, small: 10, large: 14, send: send)
                EqualizerBars(isPlaying: track.isPlaying, height: 30)
            }
        }
        .frame(height: MusicType.rowArtwork)
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 14)
        .frame(width: width, height: MusicType.rowHeight, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.spoken(track))
    }

    static func spoken(_ track: NowPlaying) -> String {
        let state = track.isPlaying ? "Now playing" : "Paused"
        return [state, track.title, track.artist].compactMap(\.self).joined(separator: ", ")
    }
}

// MARK: - The expanded surface's page

struct MusicPage: View {
    let track: NowPlaying
    let now: Date
    /// Whether the page can be seen: open, and shown or being swiped to.
    var isVisible = true
    let send: (MusicCommand) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            MusicArtwork(track: track, size: MusicType.pageArtwork, radius: 20)

            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 20) {
                    TrackText(track: track)
                    EqualizerBars(isPlaying: track.isPlaying && isVisible)
                }
                .frame(height: 34)

                // The surface redraws on a thirty-second beat, which is a
                // clock that stands still for half a minute. The position
                // keeps its own beat of a second while the track plays and
                // the page can be seen, and none otherwise: the page is built
                // whenever a track is loaded, closed or on the other page.
                TimelineView(.periodic(from: .now, by: track.isPlaying && isVisible ? 1 : 3600)) { context in
                    MusicProgress(track: track, now: context.date, send: send)
                }

                MusicControls(isPlaying: track.isPlaying, small: 14, large: 18, send: send)
                    .frame(height: 22)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 121)
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .foregroundStyle(.white)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(CompactMusicRow.spoken(track))
    }
}

/// Where the track is, and — where the source allows it — the place to drag
/// it to.
private struct MusicProgress: View {
    let track: NowPlaying
    let now: Date
    let send: (MusicCommand) -> Void

    @State private var dragged: Double?

    var body: some View {
        let duration = track.duration ?? 0
        let position = dragged.map { $0 * duration } ?? track.position(at: now) ?? 0
        let fraction = duration > 0 ? min(max(position / duration, 0), 1) : 0

        VStack(spacing: 7) {
            // The bar takes the row's width and gives nothing back to the
            // layout; the reader that measures it rides in an overlay, where
            // a GeometryReader cannot claim space.
            Capsule()
                .fill(MusicType.track)
                .frame(height: 4)
                .overlay {
                    GeometryReader { proxy in
                        // The whole width answers a drag, not only what has
                        // been played — seeking forward is the common case.
                        ZStack(alignment: .leading) {
                            Color.clear
                            Capsule()
                                .fill(.white)
                                .frame(width: proxy.size.width * fraction)
                        }
                        .contentShape(Rectangle().inset(by: -6))
                        .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        guard duration > 0 else { return }
                                        dragged = min(max(value.location.x / proxy.size.width, 0), 1)
                                    }
                                    .onEnded { _ in
                                        if let dragged, duration > 0 { send(.seek(to: dragged * duration)) }
                                        dragged = nil
                                    }
                            )
                    }
                }

            HStack {
                Text(Self.clock(position))
                Spacer()
                Text(Self.clock(duration))
            }
            .font(MusicType.time)
            .foregroundStyle(MusicType.secondary)
            .frame(height: 14)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Position")
        .accessibilityValue("\(Self.clock(position)) of \(Self.clock(duration))")
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let whole = Int(max(seconds, 0).rounded(.down))
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }
}

// MARK: - Pages

enum SurfacePage: Equatable, Sendable {
    case capacity
    case music
}

/// Which page the expanded surface shows. The last one chosen, and Capacity
/// the first time: it is the question the product answers.
@MainActor
final class SurfacePages: ObservableObject {
    @Published private(set) var selected: SurfacePage = .capacity
    /// How far the fingers have carried the pages during a swipe, in points:
    /// negative towards the next page. Zero whenever no swipe is under way.
    @Published private(set) var travel: CGFloat = 0

    func next() { turn(to: .music) }
    func previous() { turn(to: .capacity) }

    /// Follows the fingers. Under Reduce Motion the pages stay put until the
    /// swipe ends, and then change without travelling.
    func follow(_ travel: CGFloat) {
        guard !Self.reduceMotion else { return }
        self.travel = travel
    }

    /// Ends a swipe: past forty points it turns the page, short of that the
    /// pages settle back where they were.
    func settle(_ travel: CGFloat) {
        let target: SurfacePage = travel < -40 ? .music : travel > 40 ? .capacity : selected
        turn(to: target)
    }

    private func turn(to page: SurfacePage) {
        // The window takes this long to change height, on this curve; the
        // pages move with it so the two arrive together.
        withAnimation(SurfaceType.surfaceMotion(opening: true, reduced: Self.reduceMotion)) {
            selected = page
            travel = 0
        }
    }

    private static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

/// The expanded surface's pages, side by side, one surface wide each.
///
/// A layout rather than a stack, so that it stands as tall as the page shown
/// and not as the tallest page: the panel measures it to decide how far to
/// open, and the music page is 67 points shorter than Capacity. Both numbers
/// animate — how far along the pages are, and how tall — so a turn slides the
/// pages and changes the height in the same motion as the window.
struct PageStrip: Layout {
    /// 0 on the first page, 1 on the second, in between while moving.
    var position: CGFloat
    /// The same, for the height only: it follows a turn, not the fingers,
    /// because the window does not change height until the swipe ends.
    var heightPosition: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(position, heightPosition) }
        set {
            position = newValue.first
            heightPosition = newValue.second
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let first = subviews.first else { return .zero }
        let width = proposal.width ?? first.sizeThatFits(.unspecified).width
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        let lower = min(max(Int(heightPosition.rounded(.down)), 0), heights.count - 1)
        let upper = min(lower + 1, heights.count - 1)
        let fraction = heightPosition - CGFloat(lower)
        return CGSize(width: width, height: heights[lower] + (heights[upper] - heights[lower]) * fraction)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: bounds.minX + (CGFloat(index) - position) * bounds.width, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: nil)
            )
        }
    }
}

/// The open surface's footer. With a second page it holds the dots — six
/// points each in an eight-point slot, four apart — and with one page it is
/// the same band, empty.
struct PageDots: View {
    let selected: SurfacePage?

    var body: some View {
        HStack(spacing: 4) {
            if let selected {
                dot(active: selected == .capacity)
                dot(active: selected == .music)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 8)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .accessibilityHidden(true)
    }

    private func dot(active: Bool) -> some View {
        Circle()
            .fill(active ? Color.white : MusicType.secondary)
            .frame(width: 6, height: 6)
            .frame(width: 8, height: 8)
    }
}
