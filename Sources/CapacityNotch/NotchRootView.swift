import CapacityNotchCore
import SwiftUI

/// The type the surface is drawn at.
///
/// Every size here was measured, not read off a style panel. The drawing's own
/// text nodes give a width for each string; the size is whichever one renders
/// that string at that width. Two of them disagreed with what the drawing said
/// it was using — the card's figure measures 59 points for "69% left", which
/// is 15 and not the 20 declared. The widths are what the eye sees, so the
/// widths win.
enum SurfaceType {
    static let providerName = Font.system(size: 17, weight: .semibold)
    static let statusChip = Font.system(size: 11, weight: .semibold)
    static let windowLabel = Font.system(size: 15, weight: .medium)
    static let capacity = Font.system(size: 15, weight: .bold, design: .rounded)
    /// The strip's figures: 15 closed and 17 open, as the two drawings set
    /// them ("76%" measures 31 points wide closed and 35 open).
    static func compactCapacity(isExpanded: Bool) -> Font {
        .system(size: isExpanded ? 17 : 15, weight: .semibold, design: .rounded)
    }
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
    /// The surface's shape moves on springs: opening with a little give at
    /// the end, closing settled and without overshoot. The strip's width,
    /// the page turn and the shape share them, so everything that moves with
    /// the surface arrives with it.
    static func surfaceMotion(opening: Bool, reduced: Bool = false) -> Animation {
        if reduced { return .easeInOut(duration: 0.15) }
        return opening
            ? .spring(response: 0.42, dampingFraction: 0.8)
            : .spring(response: 0.45, dampingFraction: 1.0)
    }

    /// What trades places under the strip as the surface opens and closes.
    /// The outgoing thing leaves quickly; the incoming one arrives while the
    /// shape is still moving, a beat behind it, so the shape uncovers it
    /// rather than opening onto an empty black and filling in afterwards.
    static func contentMotion(appearing: Bool, reduced: Bool) -> Animation {
        if reduced { return .easeInOut(duration: 0.15) }
        return appearing
            ? .easeOut(duration: 0.22).delay(0.06)
            : .easeIn(duration: 0.1)
    }

    static let headerRow: CGFloat = 22
    static let windowRow: CGFloat = 18
    static let captionRow: CGFloat = 14
    static let provenanceRow: CGFloat = 14

    /// The drawing's own colours, spelled out. The system's named colours
    /// follow the Mac's appearance, and in Light mode they are a shade darker
    /// than the drawing on a surface that is black either way.
    static let green = Color(red: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255)
    static let yellow = Color(red: 0xFF / 255, green: 0xD6 / 255, blue: 0x0A / 255)
    static let red = Color(red: 0xFF / 255, green: 0x45 / 255, blue: 0x3A / 255)
    static let orange = Color(red: 0xFF / 255, green: 0x9F / 255, blue: 0x0A / 255)

    static let captionColour = Color.white.opacity(0x8C / 255)
    static let trackColour = Color.white.opacity(0x26 / 255)
    static let cardColour = Color.white.opacity(0x14 / 255)
    static let connectColour = Color.white.opacity(0x33 / 255)

}

/// The surface is one column: the strip that lives in the menu bar, and the
/// detail under it. Both are always built. Opening and closing changes only
/// how much of the column the window lets through, so no view is swapped for
/// another while the motion runs and nothing can jump.
struct NotchRootView: View {
    @StateObject private var store: CapacityNotchStore
    @ObservedObject private var metrics: SurfaceMetrics
    @ObservedObject private var music: MusicReader
    @ObservedObject private var teleprompter: TeleprompterController
    @ObservedObject private var pages: SurfacePages
    @ObservedObject private var shape: SurfaceShape
    private let connect: (Provider) -> Void
    private let refresh: (Provider) -> Void

    init(
        store: CapacityNotchStore,
        metrics: SurfaceMetrics,
        music: MusicReader,
        teleprompter: TeleprompterController,
        pages: SurfacePages,
        shape: SurfaceShape,
        connect: @escaping (Provider) -> Void,
        refresh: @escaping (Provider) -> Void
    ) {
        _store = StateObject(wrappedValue: store)
        self.metrics = metrics
        self.music = music
        self.teleprompter = teleprompter
        self.pages = pages
        self.shape = shape
        self.connect = connect
        self.refresh = refresh
    }

    /// Over a fullscreen application the closed surface is the strip alone: a
    /// music row would sit on the tabs or the toolbar of the application the
    /// person asked to have the whole screen. Opening it still works.
    private var compactTrack: NowPlaying? {
        metrics.isFullscreen ? nil : music.shown
    }

    var body: some View {
        // The column is laid out once, at the top of the window, and does
        // not move; only the shape moves. The shape fills the black and cuts
        // the column to itself, and it is a path — animating it redraws an
        // outline each frame rather than laying the whole column out again,
        // which is what made the spring stutter. The window is one size, the
        // open surface's and a little more; around the shape it is
        // transparent and lets the pointer through.
        let outline = NotchOutline(size: shape.size, radius: shape.radius)

        ZStack(alignment: .top) {
            outline.fill(Color.black)

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
                    playing: compactTrack,
                    loaded: music.loaded,
                    teleprompter: teleprompter,
                    page: pages.selected,
                    travel: pages.travel,
                    send: { music.send($0) },
                    connect: connect,
                    refresh: refresh
                ) {
                    // A click asks for the surface to stay, and a second
                    // one lets it go again.
                    store.togglePin()
                }
            }
            // The second way between pages, for VoiceOver: nothing on
            // screen, as the swipe is the only thing drawn.
            .accessibilityActions {
                if store.presentation == .expanded, pages.available.count > 1 {
                    Button(L("Next page")) { pages.next() }
                    Button(L("Previous page")) { pages.previous() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipShape(outline)
        .contentShape(outline)
    }
}

/// The surface's outline: square along the top, where it meets the menu bar,
/// rounded along the bottom, centred in whatever the window is.
struct NotchOutline: Shape {
    var size: CGSize
    var radius: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(size.width, size.height), radius) }
        set {
            size = CGSize(width: newValue.first.first, height: newValue.first.second)
            radius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let frame = CGRect(x: rect.midX - size.width / 2, y: rect.minY, width: size.width, height: size.height)
        let corner = min(radius, size.width / 2, size.height)
        return UnevenRoundedRectangle(
            bottomLeadingRadius: corner,
            bottomTrailingRadius: corner,
            style: .continuous
        )
        .path(in: frame)
    }
}

/// The black shape's size and corners, set by the panel and animated by it:
/// the drawing's 38 open and 28 closed.
@MainActor
final class SurfaceShape: ObservableObject {
    @Published var size: CGSize = .zero
    @Published var radius: CGFloat = 28
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
    /// The Music Module's track for the compact row: playing, or just paused.
    var playing: NowPlaying? = nil
    /// Its track for the expanded page: whatever is loaded.
    var loaded: NowPlaying? = nil
    /// The Teleprompter Module, for its row and its page; nil or off, neither.
    var teleprompter: TeleprompterController? = nil
    var page: SurfacePage = .capacity
    /// A swipe under way, in points; see `SurfacePages.travel`.
    var travel: CGFloat = 0
    var send: (MusicCommand) -> Void = { _ in }
    let connect: (Provider) -> Void
    let refresh: (Provider) -> Void
    let toggle: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            CompactCapacityView(
                snapshots: snapshots,
                geometry: geometry,
                now: now,
                isExpanded: isExpanded,
                isWide: compactRow == .teleprompter,
                toggle: toggle
            )

            // Under the strip, one place and two things to put in it: the
            // music row closed, the open surface's content open. Both are
            // always built and trade places by fading, in step with the
            // shape — the row appearing at once over cards still on their way
            // out, and cards arriving a quarter-second after the shape had
            // opened on an empty black, are what made the motion look broken.
            ZStack(alignment: .top) {
                openContent
                    .opacity(isExpanded ? 1 : 0)
                    .allowsHitTesting(isExpanded)
                    .animation(SurfaceType.contentMotion(appearing: isExpanded, reduced: reduceMotion), value: isExpanded)

                Group {
                    switch compactRow {
                    case .teleprompter:
                        if let teleprompter { TeleprompterRow(teleprompter: teleprompter) }
                    case .music:
                        if let playing { CompactMusicRow(track: playing, width: geometry.compactWidth(), send: send) }
                    case .none:
                        EmptyView()
                    }
                }
                .opacity(isExpanded ? 0 : 1)
                .allowsHitTesting(!isExpanded)
                .animation(SurfaceType.contentMotion(appearing: !isExpanded, reduced: reduceMotion), value: isExpanded)
            }
        }
        .frame(width: geometry.surfaceWidth(), alignment: .top)
        // The column keeps the height it wants, whoever asks. Offered the
        // closed window's 38 points it would otherwise squeeze itself to fit
        // and centre what is left, which put the middle of the Provider cards
        // in the strip where the menu bar row belongs — and made the panel
        // measure that squeezed height when deciding how far to open.
        .fixedSize(horizontal: false, vertical: true)
    }

    /// What sits under the compact strip. Music has already been left out
    /// over a fullscreen application; the Teleprompter Row is not.
    private var compactRow: TeleprompterSurface.CompactRow {
        TeleprompterSurface.compactRow(
            teleprompterShowing: teleprompter?.isShowingRow == true,
            musicShown: playing != nil,
            fullscreen: false
        )
    }

    private var pages: [SurfacePage] {
        SurfacePageOrder.pages(musicLoaded: loaded != nil, teleprompter: teleprompter?.isEnabled == true)
    }

    private var shownPage: SurfacePage { SurfacePageOrder.shown(page, in: pages) }

    /// Everything the open surface shows under its strip.
    private var openContent: some View {
        VStack(spacing: 0) {
            // With more than one page they are laid side by side and moved
            // together.
            if pages.count > 1 {
                PageStrip(position: stripPosition, heightPosition: CGFloat(pages.firstIndex(of: shownPage) ?? 0)) {
                    ForEach(pages, id: \.self) { candidate in
                        pageView(candidate)
                            .accessibilityHidden(candidate != shownPage)
                    }
                }
                .clipped()
            } else {
                capacityDetail
            }

            PageDots(pages: pages, selected: pages.count > 1 ? shownPage : nil)
        }
    }

    @ViewBuilder
    private func pageView(_ candidate: SurfacePage) -> some View {
        let visible = isExpanded && (candidate == shownPage || travel != 0)
        switch candidate {
        case .capacity:
            capacityDetail
        case .music:
            if let loaded {
                MusicPage(track: loaded, now: now, isVisible: visible, send: send)
            }
        case .teleprompter:
            if let teleprompter {
                TeleprompterPage(teleprompter: teleprompter, isVisible: visible)
            }
        }
    }

    /// Where the pages stand: the page chosen, moved by the fingers, and
    /// beyond either end only a third as far, so the edge gives a little and
    /// then holds.
    private var stripPosition: CGFloat {
        let width = geometry.surfaceWidth()
        let last = CGFloat(max(pages.count - 1, 0))
        let moved = CGFloat(pages.firstIndex(of: shownPage) ?? 0) - travel / width
        if moved < 0 { return moved / 3 }
        if moved > last { return last + (moved - last) / 3 }
        return moved
    }

    private var capacityDetail: some View {
        DetailCapacityView(
            snapshots: snapshots,
            now: now,
            highlighted: highlighted,
            connect: connect,
            refresh: refresh
        )
    }
}

private struct CompactCapacityView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Chosen in Settings → Providers; read here so the strip follows at once.
    @AppStorage("compactWindow") private var choice = CompactWindowChoice.fiveHour.rawValue

    let snapshots: [CapacitySnapshot]
    let geometry: NotchGeometry
    let now: Date
    let isExpanded: Bool
    /// The Teleprompter Row is as wide as the open surface, and the strip
    /// above it widens with it.
    var isWide = false
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 0) {
                let sides = CompactStrip.sides(snapshots, showing: CompactWindowChoice(rawValue: choice) ?? .fiveHour)
                if let left = sides.left { CompactSideView(side: left, now: now, isExpanded: isExpanded) }

                // Numbers drawn under the physical notch are numbers nobody
                // can read.
                Spacer(minLength: max(geometry.notchWidth, 220))

                if let right = sides.right { CompactSideView(side: right, now: now, isExpanded: isExpanded) }
            }
            .padding(.horizontal, 18)
            .frame(
                width: isExpanded || isWide ? geometry.surfaceWidth() : geometry.compactWidth(),
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
        .accessibilityLabel(L("Show or hide Capacity details"))
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

/// One side of the strip: a Provider's mark, a figure and its pace.
private struct CompactSideView: View {
    let side: CompactStrip.Side
    let now: Date
    let isExpanded: Bool

    var body: some View {
        HStack(spacing: 7) {
            ProviderMark(provider: provider, size: 15)
                .foregroundStyle(provider.presentation.tint)

            Text(figure)
                .font(SurfaceType.compactCapacity(isExpanded: isExpanded))
                .monospacedDigit()
                .foregroundStyle(.white)
                // A figure that wraps is not a figure. It keeps its own width
                // and the gap over the notch gives way instead.
                .lineLimit(1)
                .fixedSize()

            if let pace {
                PaceMark(pace: pace)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken)
    }

    private var provider: Provider {
        switch side {
        case let .provider(snapshot): snapshot.provider
        case let .window(provider, _): provider
        }
    }

    private var figure: String {
        switch side {
        case let .provider(snapshot): snapshot.compactCapacityText(at: now)
        case let .window(_, window): "\(Int(window.remainingPercentage))%"
        }
    }

    private var pace: CapacityPace? {
        switch side {
        case let .provider(snapshot): snapshot.headlineWindow?.pace
        case let .window(_, window): window.pace
        }
    }

    private var spoken: String {
        switch side {
        case let .provider(snapshot): CapacitySpeech.compact(snapshot, at: now)
        case let .window(provider, window): CapacitySpeech.compact(provider, window)
        }
    }
}

struct DetailCapacityView: View {
    let snapshots: [CapacitySnapshot]
    let now: Date
    var highlighted: CapacityNotchStore.HighlightedWindow?
    let connect: (Provider) -> Void
    let refresh: (Provider) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // With nothing connected there is no reading to date, and the
            // drawing leaves the line out: six points and then the cards.
            if let headline = CapacityProvenance.of(snapshots).headline {
                Text(headline)
                    .font(SurfaceType.caption)
                    .foregroundStyle(SurfaceType.captionColour)
                    .frame(height: SurfaceType.provenanceRow)
                    .padding(.horizontal, 18)
            }

            // A Provider switched off has no card; the other takes the width.
            HStack(spacing: 12) {
                ForEach(SurfaceCards.shown(snapshots), id: \.provider) { snapshot in
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
            // Both cards stand as tall as the taller one: the row takes the
            // height its tallest card wants, and each card fills it.
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 18)
            .padding(.top, 6)
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
        VStack(spacing: 12) {
            if let reason, reason.needsAPersonFirst {
                Text(reason.localizedGuidance)
                    .font(SurfaceType.guidance)
                    .foregroundStyle(SurfaceType.captionColour)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(action: connect) {
                Text(L("Connect"))
                    .font(SurfaceType.windowLabel)
                    .foregroundStyle(.white)
                    .frame(height: 18)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(SurfaceType.connectColour))
            }
            .buttonStyle(.plain)
            .focusable()
            .accessibilityLabel(L("Connect this Provider"))
        }
        .frame(maxWidth: .infinity)
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
                    L("Refresh %@ Capacity", snapshot.provider.presentation.displayName)
                )
            }
            .frame(height: SurfaceType.headerRow)

            if case .disconnected = snapshot.connectionState {
                // Twenty above the button and twenty under it, the card
                // otherwise padded fourteen: "Notch — Disconnected".
                ConnectAction(
                    reason: snapshot.statusReason,
                    connect: connect
                )
                .padding(.top, 20)
                .padding(.bottom, 6)
            } else if let reason = snapshot.statusReason, reason.repeatsTheChip == false {
                Text(reason.localizedGuidance)
                    .font(SurfaceType.guidance)
                    .foregroundStyle(SurfaceType.captionColour)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }

            ForEach(snapshot.windows, id: \.id) { window in
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(Localization.windowLabel(window.label))
                            .font(SurfaceType.windowLabel)
                        Spacer()
                        Text(L("%d%% left", Int(window.remainingPercentage)))
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
                        Text(L("%d%% used", Int((window.usedFraction * 100).rounded())))
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SurfaceType.cardColour)
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
            ProviderPresentation(displayName: "Codex", tint: .white)
        case .claudeCode:
            ProviderPresentation(displayName: "Claude Code", tint: SurfaceType.orange)
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
            ConnectionStatePresentation(label: L("Mock"), tint: SurfaceType.captionColour)
        case .connecting:
            ConnectionStatePresentation(label: L("Connecting"), tint: SurfaceType.captionColour)
        case .fresh:
            ConnectionStatePresentation(label: L("Fresh"), tint: SurfaceType.green)
        case .stale:
            ConnectionStatePresentation(label: L("Stale"), tint: SurfaceType.yellow)
        case .disconnected:
            // A dash, not a word. The card's body says what to do about it.
            ConnectionStatePresentation(label: "—", tint: SurfaceType.red)
        }
    }
}


private extension QuotaWindow {
    func resetText(at now: Date) -> String {
        guard let resetsAt else { return L("reset time not reported") }
        let clock = resetsAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Localization.current.locale))
        return L("resets in %@ · %@", ResetCountdown.text(until: resetsAt, at: now), clock)
    }
}

private extension CapacityPace {
    var tint: Color {
        switch self {
        case .sustainable: SurfaceType.green
        case .tightening: SurfaceType.yellow
        case .unsustainable: SurfaceType.red
        }
    }
}


private extension CapacityProvenance {
    var headline: String? {
        switch self {
        case .mock:
            L("Mock capacity")
        case let .fresh(readAt):
            L("Read at %@", readAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Localization.current.locale)))
        case let .stale(readAt):
            L("Last read at %@", readAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Localization.current.locale)))
        case .disconnected:
            nil
        }
    }
}
