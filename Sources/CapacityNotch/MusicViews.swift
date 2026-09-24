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
    static let secondary = Color.white.opacity(0.55)
    static let track = Color.white.opacity(0.15)

    static let rowHeight: CGFloat = 52
    static let rowArtwork: CGFloat = 34
    static let pageArtwork: CGFloat = 120
    static let dotsHeight: CGFloat = 18
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

/// Seven bars. Decorative: they move while the track plays, rest when it is
/// paused, and hold still under Reduce Motion. No audio is captured.
///
/// Drawn with Core Animation, not SwiftUI. Animated in SwiftUI — a timeline
/// redrawing the bars — the surface cost a fifth of a core, measured; layers
/// with repeating animations are moved by the render server, and the
/// application does nothing while they play.
struct EqualizerBars: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isPlaying: Bool

    var body: some View {
        EqualizerLayers(moving: isPlaying && !reduceMotion)
            .frame(width: EqualizerLayers.width, height: 34)
            .accessibilityHidden(true)
    }
}

private struct EqualizerLayers: NSViewRepresentable {
    static let heights: [CGFloat] = [34, 22, 18, 30, 10, 26, 30]
    static let width: CGFloat = CGFloat(heights.count) * 2 + CGFloat(heights.count - 1) * 3

    let moving: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        for (index, height) in Self.heights.enumerated() {
            let bar = CALayer()
            bar.backgroundColor = NSColor.white.withAlphaComponent(0.55).cgColor
            bar.cornerRadius = 1
            bar.frame = CGRect(x: CGFloat(index) * 5, y: (34 - height) / 2, width: 2, height: height)
            view.layer?.addSublayer(bar)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        for (index, bar) in (view.layer?.sublayers ?? []).enumerated() {
            if moving {
                guard bar.animation(forKey: "sway") == nil else { continue }
                let sway = CABasicAnimation(keyPath: "transform.scale.y")
                sway.fromValue = 1
                sway.toValue = 0.35
                // Uneven periods, so the bars never march in step.
                sway.duration = 0.45 + Double(index % 4) * 0.13
                sway.autoreverses = true
                sway.repeatCount = .infinity
                sway.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                sway.timeOffset = Double(index) * 0.21
                bar.add(sway, forKey: "sway")
            } else {
                bar.removeAnimation(forKey: "sway")
            }
        }
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
                EqualizerBars(isPlaying: track.isPlaying)
            }
        }
        .frame(height: MusicType.rowArtwork)
        .padding(.horizontal, 18)
        .padding(.bottom, 18)
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
    let send: (MusicCommand) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            MusicArtwork(track: track, size: MusicType.pageArtwork, radius: 20)

            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 20) {
                    TrackText(track: track)
                    EqualizerBars(isPlaying: track.isPlaying)
                }
                .frame(height: 34)

                MusicProgress(track: track, now: now, send: send)

                MusicControls(isPlaying: track.isPlaying, small: 14, large: 18, send: send)
                    .frame(height: 22)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 121)
        }
        .padding(18)
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
    @Published var selected: SurfacePage = .capacity

    func next() { selected = .music }
    func previous() { selected = .capacity }
}

struct PageDots: View {
    let selected: SurfacePage

    var body: some View {
        HStack(spacing: 4) {
            dot(active: selected == .capacity)
            dot(active: selected == .music)
        }
        .frame(maxWidth: .infinity)
        .frame(height: MusicType.dotsHeight)
        .accessibilityHidden(true)
    }

    private func dot(active: Bool) -> some View {
        Circle()
            .fill(active ? Color.white : MusicType.secondary)
            .frame(width: 6, height: 6)
    }
}
