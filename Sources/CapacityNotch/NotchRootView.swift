import CapacityNotchCore
import SwiftUI

/// The type the surface is drawn at.
///
/// Every size here was measured, not read off a style panel. The drawing's own
/// text nodes give a width for each string; the size is whichever one renders
/// that string at that width. Two of them disagreed with what the drawing said
/// it was using — the card's figure measures 59 points for "69% left", which
/// is 15 and not the 20 declared, and the strip's measures 35 for "76%", which
/// is 17 and not 15. The widths are what the eye sees, so the widths win.
enum SurfaceType {
    static let providerName = Font.system(size: 17, weight: .semibold)
    static let statusChip = Font.system(size: 11, weight: .semibold)
    static let windowLabel = Font.system(size: 15, weight: .medium)
    static let capacity = Font.system(size: 15, weight: .bold, design: .rounded)
    static let compactCapacity = Font.system(size: 17, weight: .semibold, design: .rounded)
    static let caption = Font.system(size: 11, weight: .regular)
    static let guidance = Font.system(size: 15, weight: .regular)
    static let refreshGlyph = Font.system(size: 17, weight: .semibold)

    /// Row heights taken from the drawing. Type is allowed to stand taller
    /// than the row it sits in — a twenty-point figure needs about
    /// twenty-four points of line — so the rhythm of the card is set by these
    /// and not by whatever leading each font happens to want.
    /// The unfolding, read off the drawing's own timeline. The surface takes
    /// half a second to open; the reading time follows it in at 200ms and the
    /// cards at 280ms, each rising a little as it arrives. Closing is brisk
    /// and undelayed — nothing is worth waiting for on the way out.
    static let openDuration = 0.5
    static let openCurve = (0.32, 0.72, 0.0, 1.0)

    /// The same motion the window is given, so the strip widens in step with
    /// it instead of jumping to its open width on the first frame and leaving
    /// the figures to sit there while the window catches up.
    static func surfaceMotion(opening: Bool, reduced: Bool = false) -> Animation {
        if reduced { return .easeInOut(duration: 0.15) }
        return opening
            ? .timingCurve(openCurve.0, openCurve.1, openCurve.2, openCurve.3,
                           duration: openDuration)
            : .timingCurve(0.4, 0, 0.7, 1, duration: 0.26)
    }

    /// Reduce Motion keeps the change and drops the travel: things still fade
    /// in, in the same order, but nothing slides and nothing is held back.
    static func provenanceMotion(opening: Bool, reduced: Bool) -> Animation {
        if reduced { return .easeInOut(duration: 0.15) }
        return opening
            ? .timingCurve(0.25, 0.1, 0.25, 1, duration: 0.25).delay(0.20)
            : .easeIn(duration: 0.12)
    }

    static func cardsMotion(opening: Bool, reduced: Bool) -> Animation {
        if reduced { return .easeInOut(duration: 0.15) }
        return opening
            ? .timingCurve(0.25, 0.1, 0.25, 1, duration: 0.27).delay(0.28)
            : .easeIn(duration: 0.12)
    }

    static let headerRow: CGFloat = 22
    static let windowRow: CGFloat = 18
    static let captionRow: CGFloat = 14
    static let provenanceRow: CGFloat = 16

    static let captionColour = Color.white.opacity(0.55)
    static let trackColour = Color.white.opacity(0.15)
}

/// The surface is one column: the strip that lives in the menu bar, and the
/// detail under it. Both are always built. Opening and closing changes only
/// how much of the column the window lets through, so no view is swapped for
/// another while the motion runs and nothing can jump.
struct NotchRootView: View {
    @StateObject private var store: CapacityNotchStore
    @ObservedObject private var metrics: SurfaceMetrics
    private let connect: (Provider) -> Void
    private let refresh: (Provider) -> Void

    init(
        store: CapacityNotchStore,
        metrics: SurfaceMetrics,
        connect: @escaping (Provider) -> Void,
        refresh: @escaping (Provider) -> Void
    ) {
        _store = StateObject(wrappedValue: store)
        self.metrics = metrics
        self.connect = connect
        self.refresh = refresh
    }

    var body: some View {
        // The background decides the size and takes whatever the window
        // gives it. The column rides on top as an overlay, which contributes
        // nothing to that size, so it can keep its natural height without
        // either squeezing itself or telling the window how tall to be.
        Color.black
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) {
                // Capacity Pace and a countdown both depend on the time, so
                // the surface is redrawn on a slow beat rather than only when
                // a Provider answers.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    SurfaceColumn(
                        snapshots: store.snapshots,
                        geometry: metrics.geometry,
                        now: context.date,
                        highlighted: store.highlighted,
                        isExpanded: store.presentation == .expanded,
                        connect: connect,
                        refresh: refresh
                    ) {
                        // A click asks for the surface to stay, and a second
                        // one lets it go again.
                        store.togglePin()
                    }
                }
            }
            .clipShape(
                UnevenRoundedRectangle(
                    bottomLeadingRadius: 38,
                    bottomTrailingRadius: 38,
                    style: .continuous
                )
            )
    }
}

/// The column on its own, with the height it wants and no filling.
///
/// The panel measures this to decide how tall to open. A view told to fill its
/// window reports the window's height back, not the height of its content,
/// which is how the surface came to open too short and cut off a Quota Window.
struct SurfaceColumn: View {
    let snapshots: [CapacitySnapshot]
    let geometry: NotchGeometry
    let now: Date
    var highlighted: CapacityNotchStore.HighlightedWindow?
    let isExpanded: Bool
    let connect: (Provider) -> Void
    let refresh: (Provider) -> Void
    let toggle: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            CompactCapacityView(
                snapshots: snapshots,
                geometry: geometry,
                now: now,
                isExpanded: isExpanded,
                toggle: toggle
            )

            DetailCapacityView(
                snapshots: snapshots,
                now: now,
                highlighted: highlighted,
                isExpanded: isExpanded,
                connect: connect,
                refresh: refresh
            )
        }
        .frame(width: geometry.surfaceWidth(), alignment: .top)
        // The column keeps the height it wants, whoever asks. Offered the
        // closed window's 38 points it would otherwise squeeze itself to fit
        // and centre what is left, which put the middle of the Provider cards
        // in the strip where the menu bar row belongs — and made the panel
        // measure that squeezed height when deciding how far to open.
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct CompactCapacityView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let snapshots: [CapacitySnapshot]
    let geometry: NotchGeometry
    let now: Date
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 0) {
                if let codex = snapshots.first(where: { $0.provider == .codex }) {
                    CompactProviderView(snapshot: codex, now: now)
                }

                // Numbers drawn under the physical notch are numbers nobody
                // can read.
                Spacer(minLength: max(geometry.notchWidth, 104))

                if let claude = snapshots.first(where: { $0.provider == .claudeCode }) {
                    CompactProviderView(snapshot: claude, now: now)
                }
            }
            .padding(.horizontal, 18)
            .frame(
                width: isExpanded ? geometry.surfaceWidth() : geometry.compactWidth(),
                height: geometry.menuBarHeight,
                alignment: .center
            )
            .animation(
                SurfaceType.surfaceMotion(opening: isExpanded, reduced: reduceMotion),
                value: isExpanded
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show or hide Capacity details")
    }
}

/// Six points of colour. A dot, whatever the state.
///
/// Shapes were tried here and were worse: at six points a triangle keeps under
/// half a dot's area and a square reads heavier than either, so telling the
/// three apart cost more visibility than it bought. Nothing replaced them,
/// because nothing needed to — the figure beside the dot already says which
/// state this is, in a channel that is not colour.
private struct PaceMark: View {
    let pace: CapacityPace

    var body: some View {
        Circle()
            .fill(pace.tint)
            .frame(width: 6, height: 6)
            .accessibilityHidden(true)
    }
}

private struct CompactProviderView: View {
    let snapshot: CapacitySnapshot
    let now: Date

    var body: some View {
        HStack(spacing: 7) {
            ProviderMark(provider: snapshot.provider, size: 15)
                .foregroundStyle(snapshot.provider.presentation.tint)

            Text(snapshot.compactCapacityText(at: now))
                .font(SurfaceType.compactCapacity)
                .monospacedDigit()
                .foregroundStyle(.white)
                // A figure that wraps is not a figure. It keeps its own width
                // and the gap over the notch gives way instead.
                .lineLimit(1)
                .fixedSize()

            if let pace = snapshot.headlineWindow?.pace {
                PaceMark(pace: pace)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(CapacitySpeech.compact(snapshot, at: now))
    }
}

struct DetailCapacityView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let snapshots: [CapacitySnapshot]
    let now: Date
    var highlighted: CapacityNotchStore.HighlightedWindow?
    var isExpanded = true
    let connect: (Provider) -> Void
    let refresh: (Provider) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(CapacityProvenance.of(snapshots).headline)
                .font(SurfaceType.caption)
                .foregroundStyle(SurfaceType.captionColour)
                .frame(height: SurfaceType.provenanceRow)
                .padding(.horizontal, 18)
                .padding(.top, 2)
                .opacity(isExpanded ? 1 : 0)
                .offset(y: isExpanded || reduceMotion ? 0 : 6)
                .animation(
                    SurfaceType.provenanceMotion(opening: isExpanded, reduced: reduceMotion),
                    value: isExpanded
                )

            HStack(spacing: 12) {
                ForEach(snapshots, id: \.provider) { snapshot in
                    ProviderCard(
                        snapshot: snapshot,
                        now: now,
                        highlighted: highlighted?.provider == snapshot.provider
                            ? highlighted?.windowID
                            : nil,
                        connect: { connect(snapshot.provider) },
                        refresh: { refresh(snapshot.provider) }
                    )
                }
            }
            .padding(18)
            .opacity(isExpanded ? 1 : 0)
            .offset(y: isExpanded || reduceMotion ? 0 : 14)
            .animation(
                SurfaceType.cardsMotion(opening: isExpanded, reduced: reduceMotion),
                value: isExpanded
            )
        }
        .foregroundStyle(.white)
    }
}

/// Four points of capacity on a faint ground, filled to what is left.
private struct CapacityTrack: View {
    let remainingPercentage: Double
    let tint: Color

    var body: some View {
        Capsule()
            .fill(SurfaceType.trackColour)
            .frame(height: 4)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(tint)
                        .frame(
                            width: proxy.size.width
                                * min(max(remainingPercentage / 100, 0), 1)
                        )
                }
            }
    }
}

/// What an unread Provider offers: the one button that starts it, and the
/// sentence only when a button cannot finish the job — an install or a
/// sign-in is not something Connect can do.
private struct ConnectAction: View {
    let reason: CapacityStatusReason?
    let connect: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            if let reason, reason.needsAPersonFirst {
                Text(reason.guidance)
                    .font(SurfaceType.guidance)
                    .foregroundStyle(SurfaceType.captionColour)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(action: connect) {
                Text("Connect")
                    .font(SurfaceType.windowLabel)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Color.white.opacity(0.22)))
            }
            .buttonStyle(.plain)
            .focusable()
            .accessibilityLabel("Connect this Provider")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }
}

struct ProviderCard: View {
    let snapshot: CapacitySnapshot
    let now: Date
    /// The window an alert was about, when it is this Provider's.
    var highlighted: String?
    let connect: () -> Void
    let refresh: () -> Void

    var body: some View {
        // The gaps are set on the pieces rather than on the stack. A branch
        // that renders nothing still occupies a slot, and the stack spaced
        // around it — twelve points of nothing, which put the card twelve
        // points taller than it was drawn.
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ProviderMark(provider: snapshot.provider, size: 17)
                    .foregroundStyle(snapshot.provider.presentation.tint)

                Text(snapshot.provider.presentation.displayName)
                    .font(SurfaceType.providerName)

                Spacer()

                Text(snapshot.connectionState.presentation.label)
                    .font(SurfaceType.statusChip)
                    .foregroundStyle(snapshot.connectionState.presentation.tint)

                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(SurfaceType.refreshGlyph)
                        .foregroundStyle(.white)
                        .frame(width: 14, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable()
                .accessibilityLabel(
                    "Refresh \(snapshot.provider.presentation.displayName) Capacity"
                )
            }
            .frame(height: SurfaceType.headerRow)

            if case .disconnected = snapshot.connectionState {
                ConnectAction(
                    reason: snapshot.statusReason,
                    connect: connect
                )
                .padding(.top, 12)
            } else if let reason = snapshot.statusReason, reason.repeatsTheChip == false {
                Text(reason.guidance)
                    .font(SurfaceType.guidance)
                    .foregroundStyle(SurfaceType.captionColour)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }

            ForEach(snapshot.windows, id: \.id) { window in
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(window.label)
                            .font(SurfaceType.windowLabel)
                        Spacer()
                        Text("\(Int(window.remainingPercentage))% left")
                            .font(SurfaceType.capacity)
                            .monospacedDigit()
                            .foregroundStyle(window.pace.tint)
                    }
                    .frame(height: SurfaceType.windowRow)

                    CapacityTrack(
                        remainingPercentage: window.remainingPercentage,
                        tint: window.pace.tint
                    )

                    HStack(spacing: 5) {
                        Text("\(Int((window.usedFraction * 100).rounded()))% used")
                        Text("·")
                        Text(window.resetText(at: now))
                    }
                    .font(SurfaceType.caption)
                    .foregroundStyle(SurfaceType.captionColour)
                    .frame(height: SurfaceType.captionRow)
                }
                .padding(.top, 12)
                .padding(.horizontal, highlighted == window.id ? 8 : 0)
                .background {
                    if highlighted == window.id {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.45), lineWidth: 1)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(CapacitySpeech.window(window, at: now))
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        // Both cards stand the same height whatever each one holds, so a
        // Provider offering a Connect button does not sit shorter than one
        // showing two windows.
        .frame(
            maxWidth: .infinity,
            minHeight: 154,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(CapacitySpeech.provider(snapshot, at: now))
    }
}

private extension CapacitySnapshot {
    func compactCapacityText(at now: Date) -> String {
        guard let headline = headlineWindow else { return "—" }
        return "\(Int(headline.remainingPercentage))%"
    }
}

private struct ProviderPresentation {
    let displayName: String
    let tint: Color
}

private extension Provider {
    var presentation: ProviderPresentation {
        switch self {
        case .codex:
            ProviderPresentation(displayName: "Codex", tint: .mint)
        case .claudeCode:
            ProviderPresentation(displayName: "Claude Code", tint: .orange)
        }
    }
}

private struct ConnectionStatePresentation {
    let label: String
    let tint: Color
}

private extension CapacityConnectionState {
    var presentation: ConnectionStatePresentation {
        switch self {
        case .mock:
            ConnectionStatePresentation(label: "Mock", tint: .secondary)
        case .connecting:
            ConnectionStatePresentation(label: "Connecting", tint: .secondary)
        case .fresh:
            ConnectionStatePresentation(label: "Fresh", tint: .green)
        case .stale:
            ConnectionStatePresentation(label: "Stale", tint: .yellow)
        case .disconnected:
            // A dash, not a word. The card's body says what to do about it.
            ConnectionStatePresentation(label: "—", tint: .red)
        }
    }
}


private extension QuotaWindow {
    func resetText(at now: Date) -> String {
        guard let resetsAt else { return "reset time not reported" }
        let clock = resetsAt.formatted(date: .omitted, time: .shortened)
        return "resets in \(ResetCountdown.text(until: resetsAt, at: now)) · \(clock)"
    }
}

private extension CapacityPace {
    var tint: Color {
        switch self {
        case .sustainable: .green
        case .tightening: .yellow
        case .unsustainable: .red
        }
    }
}


private extension CapacityProvenance {
    var headline: String {
        switch self {
        case .mock:
            "Mock capacity"
        case let .fresh(readAt):
            "Read at \(readAt.formatted(date: .omitted, time: .shortened))"
        case let .stale(readAt):
            "Last read at \(readAt.formatted(date: .omitted, time: .shortened))"
        case .disconnected:
            "No Provider connected"
        }
    }
}
