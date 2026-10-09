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
    static let providerName = geist(17, .semibold)
    static let statusChip = Font.system(size: 11, weight: .semibold)
    static let windowLabel = geist(15, .medium)
    /// The strip's figures: 15, closed and open alike, as the Geist drawings
    /// set them.
    static let compactCapacity = geist(15, .medium)
    static let caption = geist(11)
    static let guidance = geist(15)
    static let refreshGlyph = Font.system(size: 17, weight: .semibold)

    /// Geist, as in Settings (`SettingsType`), for everything the surface
    /// says. The status chip and the glyphs stay in the system's font, as the
    /// drawings keep them.
    static func geist(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Font.custom("Geist", fixedSize: size).weight(weight)
    }

    /// The same, where text is measured and drawn by AppKit. The system's font
    /// stands in if Geist was not registered.
    static func geistNSFont(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: "Geist",
            .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue],
        ])
        return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }

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
    @ObservedObject private var shelf: ShelfController
    @ObservedObject private var calendar: CalendarReader
    private let translator: TranslatorController?
    private let pointer: SurfacePointer
    private let connect: (Provider) -> Void
    private let refresh: (Provider) -> Void
    private let openProviderSettings: () -> Void

    init(
        store: CapacityNotchStore,
        metrics: SurfaceMetrics,
        music: MusicReader,
        teleprompter: TeleprompterController,
        shelf: ShelfController,
        calendar: CalendarReader,
        translator: TranslatorController? = nil,
        pages: SurfacePages,
        shape: SurfaceShape,
        pointer: SurfacePointer,
        connect: @escaping (Provider) -> Void,
        refresh: @escaping (Provider) -> Void,
        openProviderSettings: @escaping () -> Void
    ) {
        _store = StateObject(wrappedValue: store)
        self.metrics = metrics
        self.music = music
        self.teleprompter = teleprompter
        self.shelf = shelf
        self.calendar = calendar
        self.translator = translator
        self.pointer = pointer
        self.pages = pages
        self.shape = shape
        self.connect = connect
        self.refresh = refresh
        self.openProviderSettings = openProviderSettings
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
                    musicOn: music.isOn,
                    remembered: music.remembered,
                    teleprompter: teleprompter,
                    shelf: shelf,
                    upcoming: calendar.rowEvent,
                    calendarEvents: calendar.showsPage ? calendar.events : nil,
                    calendarTab: calendar.tab,
                    calendarSelectedDay: calendar.selectedDay,
                    selectCalendarTab: { [calendar] in calendar.select($0) },
                    selectCalendarDay: { [calendar] in calendar.selectDay($0) },
                    hideEvent: { [calendar] in calendar.hideFromRow($0) },
                    translator: translator,
                    pointer: pointer,
                    page: pages.selected,
                    travel: pages.travel,
                    controlsShown: pages.controlsShown,
                    selectPage: { pages.select($0) },
                    send: { music.send($0) },
                    openProviderSettings: openProviderSettings,
                    connect: connect,
                    refresh: refresh
                ) {
                    // A click asks for the surface to stay, and a second
                    // one lets it go again.
                    store.togglePin()
                    Sounds.shared.play(.surfacePinned)
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
        // `SurfacePointer` is in these coordinates: the window's, from its top left.
        .coordinateSpace(name: SurfacePointer.space)
    }
}

/// The surface's outline (`SurfaceOutline`), centred in whatever the window
/// is.
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

    static let shoulder = SurfaceOutline.shoulder

    func path(in rect: CGRect) -> Path {
        Path(SurfaceOutline.path(in: rect, size: size, radius: radius))
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
    /// The Music Module is on: its page stands whether or not anything plays.
    var musicOn = false
    /// What the page shows once nothing is loaded: the last track, if any.
    var remembered: RememberedTrack? = nil
    /// The Teleprompter Module, for its row and its page; nil or off, neither.
    var teleprompter: TeleprompterController? = nil
    /// The Shelf Module, for its page; nil or off, none.
    var shelf: ShelfController? = nil
    /// The Calendar Module's event about to start, for the row beneath the
    /// strip; already left out over a fullscreen application.
    var upcoming: CalendarEvent? = nil
    /// Its events, for the day page; nil while off or not allowed, no page.
    var calendarEvents: [CalendarEvent]? = nil
    /// The Calendar page's view, and the Month's day clicked (nil: today).
    var calendarTab: CalendarTab = .standard
    var calendarSelectedDay: Date? = nil
    var selectCalendarTab: (CalendarTab) -> Void = { _ in }
    var selectCalendarDay: (Date) -> Void = { _ in }
    /// The pictures draw the page at a moment of their own, not the clock's.
    var calendarLiveClock = true
    var join: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// The row's ✕: that occurrence leaves the row until it is over.
    var hideEvent: (CalendarEvent) -> Void = { _ in }
    /// The Translator Module, for its page; nil or off, none.
    var translator: TranslatorController? = nil
    /// Where the pointer is, for what lights under it; none while measuring.
    var pointer = SurfacePointer()
    var page: SurfacePage = .capacity
    /// A swipe under way, in points; see `SurfacePages.travel`.
    var travel: CGFloat = 0
    /// The page dots have become buttons; see `SurfacePages.controlsShown`.
    var controlsShown = false
    var selectPage: (SurfacePage) -> Void = { _ in }
    var send: (MusicCommand) -> Void = { _ in }
    var openProviderSettings: () -> Void = {}
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

                VStack(spacing: 0) {
                    switch compactRow {
                    case .teleprompter:
                        if let teleprompter { TeleprompterRow(teleprompter: teleprompter) }
                    case .music:
                        if let playing { CompactMusicRow(track: playing, width: geometry.compactWidth(), send: send) }
                    case .calendar:
                        if let upcoming { CompactCalendarRow(event: upcoming, now: now, width: geometry.compactWidth(), join: join, hide: { hideEvent(upcoming) }) }
                    case .none:
                        EmptyView()
                    }
                }
                .environment(\.kapaAwake, !isExpanded)
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
            fullscreen: false,
            calendarShown: upcoming != nil
        )
    }

    private var pages: [SurfacePage] {
        SurfacePageOrder.pages(
            music: musicOn || loaded != nil,
            teleprompter: teleprompter?.isEnabled == true,
            shelf: shelf?.isEnabled == true,
            calendar: calendarEvents != nil,
            translator: translator?.isEnabled == true
        )
    }

    private var shownPage: SurfacePage { SurfacePageOrder.shown(page, in: pages) }

    /// The room every page leaves between its content and the surface's
    /// sides.
    private static let pageMargin: CGFloat = 18

    /// Everything the open surface shows under its strip. Every page has the
    /// same room, so the surface does not change height as pages turn: what
    /// a page leaves of it stays empty below, and a page that outgrew it would
    /// be cut at the bottom rather than push the dots down — so each is drawn
    /// to fit, and the picture dump is where a page that does not shows.
    private var openContent: some View {
        VStack(spacing: 0) {
            // With more than one page they are laid side by side and moved
            // together.
            if pages.count > 1 {
                PageStrip(position: stripPosition, heightPosition: CGFloat(pages.firstIndex(of: shownPage) ?? 0)) {
                    ForEach(pages, id: \.self) { candidate in
                        pageView(candidate)
                            .frame(height: NotchGeometry.pageHeight, alignment: .top)
                            .accessibilityHidden(candidate != shownPage)
                    }
                }
                // Turning, a page fades out over the margin every page keeps
                // to its edge, rather than running on to the outline and
                // being cut there — across the rounded corners, it looked
                // like the next page poking out of the surface. At rest
                // nothing reaches the margin, so nothing fades.
                .mask {
                    HStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                            .frame(width: Self.pageMargin)
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: Self.pageMargin)
                    }
                }
            } else {
                capacityDetail
                    .frame(height: NotchGeometry.pageHeight, alignment: .top)
                    .clipped()
            }

            PageSwitcher(
                pages: pages,
                selected: pages.count > 1 ? shownPage : nil,
                running: teleprompter?.playback.state == .running ? [.teleprompter] : [],
                showsButtons: controlsShown,
                pointer: pointer,
                select: selectPage
            )
        }
    }

    @ViewBuilder
    private func pageView(_ candidate: SurfacePage) -> some View {
        let visible = isExpanded && (candidate == shownPage || travel != 0)
        Group {
            pageContent(candidate, visible: visible)
        }
        .environment(\.kapaAwake, visible)
    }

    @ViewBuilder
    private func pageContent(_ candidate: SurfacePage, visible: Bool) -> some View {
        switch candidate {
        case .capacity:
            capacityDetail
        case .music:
            if let loaded {
                MusicPage(track: loaded, now: now, isVisible: visible, send: send)
            } else {
                MusicIdlePage(remembered: remembered)
            }
        case .teleprompter:
            if let teleprompter {
                TeleprompterPage(teleprompter: teleprompter, isVisible: visible)
            }
        case .shelf:
            if let shelf {
                ShelfPage(shelf: shelf, pointer: pointer, isVisible: visible)
            }
        case .calendar:
            if let calendarEvents {
                CalendarPage(
                    events: calendarEvents, now: now, liveClock: calendarLiveClock,
                    tab: calendarTab, selectedDay: calendarSelectedDay,
                    selectTab: selectCalendarTab, selectDay: selectCalendarDay, join: join
                )
            }
        case .translator:
            if let translator {
                TranslatorPage(translator: translator)
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
            refresh: refresh,
            openProviderSettings: openProviderSettings
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
                // can read; the notch itself is the gap, and no more.
                Spacer(minLength: geometry.notchWidth)

                if let right = sides.right { CompactSideView(side: right, now: now, isExpanded: isExpanded) }
            }
            .padding(.horizontal, isExpanded || isWide ? 18 : 12)
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
                .font(SurfaceType.compactCapacity)
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
        case let .window(provider, _), let .missing(provider): provider
        }
    }

    private var figure: String {
        switch side {
        case let .provider(snapshot): snapshot.compactCapacityText(at: now)
        case let .window(_, window): "\(Int(window.remainingPercentage))%"
        case .missing: "—"
        }
    }

    private var pace: CapacityPace? {
        switch side {
        case let .provider(snapshot): snapshot.headlineWindow?.pace
        case let .window(_, window): window.pace
        case .missing: nil
        }
    }

    private var spoken: String {
        switch side {
        case let .provider(snapshot): CapacitySpeech.compact(snapshot, at: now)
        case let .window(provider, window): CapacitySpeech.compact(provider, window)
        case let .missing(provider): "\(provider.presentation.displayName): \(L("No data"))"
        }
    }
}

struct DetailCapacityView: View {
    let snapshots: [CapacitySnapshot]
    let now: Date
    var highlighted: CapacityNotchStore.HighlightedWindow?
    let connect: (Provider) -> Void
    let refresh: (Provider) -> Void
    var openProviderSettings: () -> Void = {}

    var body: some View {
        let offered = SurfaceCards.offered(snapshots)
        if offered.isEmpty {
            cards
        } else {
            NothingConnectedView(providers: offered, openSettings: openProviderSettings)
        }
    }

    private var cards: some View {
        // The cards stand straight under the strip, as in "Limits — C ·
        // Gauges": the page has 152 points, and a line saying when Capacity
        // was read would not leave the gauges theirs. Each card's chip says
        // whether it is fresh.
        let shown = SurfaceCards.shown(snapshots)
        // One Kapa a page, on the card whose state it shows (ADR 0006).
        let kapa = KapaMood.capacityFocus(shown)
        return VStack(alignment: .leading, spacing: 0) {
            // A Provider switched off has no card; the other takes the width.
            HStack(spacing: 12) {
                ForEach(shown, id: \.provider) { snapshot in
                    ProviderCard(
                        snapshot: snapshot,
                        now: now,
                        isWide: shown.count == 1,
                        highlighted: highlighted?.provider == snapshot.provider
                            ? highlighted?.windowID
                            : nil,
                        kapa: kapa?.provider == snapshot.provider ? kapa?.expression : nil,
                        connect: { connect(snapshot.provider) },
                        refresh: { refresh(snapshot.provider) }
                    )
                }
            }
            // Both cards fill the page's height, so they stand as tall as each
            // other and as the drawing.
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 18)
        }
        .foregroundStyle(.white)
    }
}

/// Nothing connected ("Notch — Disconnected · Three Providers"): every
/// Provider's mark, a line, and one button to Settings ▸ Providers, where
/// connecting — and its consent — happens. No Provider is connected from here.
private struct NothingConnectedView: View {
    let providers: [Provider]
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 22) {
                // Nothing connected yet: the first thing Kapa does is say hello.
                WithKapa { KapaView(expression: .hello, size: 30) }
                ForEach(providers, id: \.self) { provider in
                    ProviderMark(provider: provider, size: 28)
                        .foregroundStyle(provider.presentation.tint)
                        .accessibilityLabel(provider.presentation.displayName)
                }
            }
            .accessibilityElement(children: .combine)

            Text(L("Connect up to two in Settings"))
                .font(SurfaceType.geist(13, .medium))
                .foregroundStyle(SurfaceType.captionColour)
                .lineLimit(1)

            CapsuleButton(title: L("Open Settings"), inset: 14, action: openSettings)
                .accessibilityLabel(L("Open Provider Settings"))
        }
        // Centred in the page's 152, six points lower than the middle, as in
        // "Notch — Disconnected · Three Providers".
        .padding(.top, 6)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The surface's one kind of button: a word on a pale capsule ("Notch —
/// Disconnected").
private struct CapsuleButton: View {
    let title: String
    /// Either side of the word: twelve for Connect, fourteen for Settings.
    let inset: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(SurfaceType.windowLabel)
                .foregroundStyle(.white)
                .frame(height: 18)
                .padding(.horizontal, inset)
                .padding(.vertical, 10)
                .background(Capsule().fill(SurfaceType.connectColour))
        }
        .buttonStyle(.plain)
        .focusable()
    }
}

/// What an unread Provider offers: the one button that starts it — or,
/// when a button cannot finish the job, since an install or a sign-in is not
/// something Connect can do, only the sentence saying what to do, in two
/// lines at most ("Limits — C · Exhausted + No data"). The refresh button in
/// the header tries again once it is done.
private struct ConnectAction: View {
    let reason: CapacityStatusReason?
    let connect: () -> Void

    var body: some View {
        if let reason, reason.needsAPersonFirst {
            Text(reason.localizedGuidance)
                .font(SurfaceType.guidance)
                .foregroundStyle(SurfaceType.captionColour)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            CapsuleButton(title: L("Connect"), inset: 12, action: connect)
                .accessibilityLabel(L("Connect this Provider"))
                .frame(maxWidth: .infinity)
        }
    }
}

struct ProviderCard: View {
    let snapshot: CapacitySnapshot
    let now: Date
    /// The only card on the surface: its gauges have the width, and room
    /// beside them for what they leave out ("Limits — C · One provider").
    var isWide = false
    /// The window an alert was about, when it is this Provider's.
    var highlighted: String?
    /// Kapa's pose, on the one card of the page that has it.
    var kapa: KapaExpression?
    let connect: () -> Void
    let refresh: () -> Void

    var body: some View {
        // The gaps are set on the pieces rather than on the stack. A branch
        // that renders nothing still occupies a slot, and the stack spaced
        // around it — twelve points of nothing, which put the card twelve
        // points taller than it was drawn.
        VStack(alignment: .leading, spacing: 0) {
            // Six apart, as drawn: at eight a long name and "Connecting"
            // do not both fit beside the refresh button.
            HStack(spacing: 6) {
                ProviderMark(provider: snapshot.provider, size: 17)
                    .foregroundStyle(snapshot.provider.presentation.tint)

                // Kapa beside the name while there is room for both, smaller
                // where "Claude Code" and a chip leave little — on a half card
                // "Stale" leaves 25 points — and gone where there is none: the
                // name is what has to stay.
                ViewThatFits(in: .horizontal) {
                    if let kapa {
                        HStack(spacing: 6) {
                            providerName
                            WithKapa { KapaView(expression: kapa, size: 26) }
                        }
                        HStack(spacing: 3) {
                            providerName
                            WithKapa { KapaView(expression: kapa, size: 20) }
                        }
                    }
                    providerName
                }
                // Measured against what the chip leaves, not a share of it: the
                // row would otherwise split the slack between this and the
                // chip, and Kapa would never find its 25 points.
                .layoutPriority(1)

                Spacer(minLength: 0)

                Text(chip.label)
                    .font(SurfaceType.statusChip)
                    .foregroundStyle(chip.tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    // Measured first: what the chip says outranks Kapa.
                    .layoutPriority(2)

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
            } else if snapshot.windows.isEmpty {
                // Nothing read yet. A reason worth a sentence takes the
                // place — the gauges would not fit under two lines of it —
                // and otherwise the gauges hold their places, empty, so the
                // card keeps its shape while it waits.
                if let reason = snapshot.statusReason, reason.repeatsTheChip == false {
                    Text(reason.localizedGuidance)
                        .font(SurfaceType.guidance)
                        .foregroundStyle(SurfaceType.captionColour)
                        .lineLimit(2)
                        .padding(.top, 10)
                } else {
                    gauges(of: [nil, nil])
                }
            } else if case .claudeNextReply? = snapshot.statusReason, let reason = snapshot.statusReason {
                // Refresh found nothing newer, and Claude Code cannot be
                // asked: where the next reading comes from, and how old
                // this one is, for a few seconds in the gauges' place.
                Text(reason.localizedGuidance(at: now))
                    .font(SurfaceType.guidance)
                    .foregroundStyle(SurfaceType.captionColour)
                    .lineLimit(2)
                    .padding(.top, 10)
            } else {
                gauges(of: GaugeSlot.slots(for: snapshot).map { Optional($0) })
                    // Old numbers are shown, but not as if they were new.
                    .opacity(snapshot.connectionState == .stale ? 0.5 : 1)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        // Both cards the same width, whatever their names and chips ask for.
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SurfaceType.cardColour)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(CapacitySpeech.provider(snapshot, at: now))
    }

    private var providerName: some View {
        Text(snapshot.provider.presentation.displayName)
            .font(SurfaceType.providerName)
            .fixedSize()
    }

    /// What the header's chip says. A Provider that cannot be read until a
    /// person does something says it has no data, in red, and the sentence
    /// under it says what to do.
    private var chip: ConnectionStatePresentation {
        if case .disconnected = snapshot.connectionState, snapshot.statusReason?.needsAPersonFirst == true {
            return ConnectionStatePresentation(label: L("No data"), tint: SurfaceType.red)
        }
        // OpenCode's month used up stops work however green the windows are,
        // so it takes the chip's place, in red. A half-width card has room
        // only for the short form.
        if case let .openCodeMonthlyLimitReached(until)? = snapshot.statusReason {
            guard isWide, let until else { return ConnectionStatePresentation(label: L("Month used up"), tint: SurfaceType.red) }
            let date = until.formatted(Date.FormatStyle().day().month(.abbreviated).locale(Localization.current.locale))
            return ConnectionStatePresentation(label: L("Monthly limit reached · until %@", date), tint: SurfaceType.red)
        }
        return snapshot.connectionState.presentation
    }

    /// The windows as gauges, side by side; an empty place for a window not
    /// read yet, and one saying there is no data for a window not sent.
    @ViewBuilder
    private func gauges(of slots: [GaugeSlot?]) -> some View {
        HStack(spacing: isWide ? 8 : 0) {
            ForEach(Array(slots.enumerated()), id: \.offset) { _, slot in
                let window: QuotaWindow? = if case let .read(window)? = slot { window } else { nil }
                let missing: String? = if case let .missing(label)? = slot { label } else { nil }
                let gauge = CapacityGauge(
                    window: window,
                    now: now,
                    placeholder: chip.label,
                    missingLabel: missing,
                    showsLabel: !isWide || missing != nil,
                    isHighlighted: window.map { $0.id == highlighted } ?? false
                )
                if isWide {
                    HStack(spacing: 14) {
                        gauge
                        if let window { WideGaugeDetail(window: window, now: now) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    gauge.frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
    }
}

/// One Quota Window as an open arc ("Limits — C · Gauges"): 270°, opening
/// downwards, filled from the lower left to what is left, the share in the
/// middle, the window under it, and when it comes back in the gap. A window
/// used up tints its whole track red. Nil is a window not read yet: an empty
/// arc and two quiet bars where the numbers will be.
struct CapacityGauge: View {
    let window: QuotaWindow?
    let now: Date
    /// What VoiceOver says for a window not read yet: the card's own chip.
    let placeholder: String
    /// A window the Provider keeps but did not send: its name, under a dash,
    /// on an empty track.
    var missingLabel: String?
    var showsLabel = true
    var isHighlighted = false

    private let size: CGFloat = 88
    private let lineWidth: CGFloat = 7

    var body: some View {
        ZStack {
            arc(to: 1)
                .stroke(trackColour, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            if let window, !window.isUsedUp {
                arc(to: window.remainingFraction)
                    .stroke(window.pace.tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }

            if let window {
                VStack(spacing: 0) {
                    Text("\(Int(window.remainingPercentage))%")
                        .font(SurfaceType.geist(22, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(window.isUsedUp ? SurfaceType.red : Color.white)
                    if showsLabel {
                        Text(Localization.windowLabel(window.label))
                            .font(SurfaceType.caption)
                            .foregroundStyle(Color.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }
                VStack {
                    Spacer()
                    Text(resetText(window))
                        .font(SurfaceType.caption)
                        .foregroundStyle(window.isUsedUp ? SurfaceType.red : SurfaceType.captionColour)
                        .lineLimit(1)
                }
            } else if let missingLabel {
                VStack(spacing: 0) {
                    Text("—")
                        .font(SurfaceType.geist(22, .semibold))
                        .foregroundStyle(SurfaceType.captionColour)
                    Text(Localization.windowLabel(missingLabel))
                        .font(SurfaceType.caption)
                        .foregroundStyle(Color.white.opacity(0.6))
                        .lineLimit(1)
                }
                VStack {
                    Spacer()
                    Text(L("No data"))
                        .font(SurfaceType.caption)
                        .foregroundStyle(SurfaceType.captionColour)
                        .lineLimit(1)
                }
            } else {
                VStack(spacing: 6) {
                    Capsule().fill(Color.white.opacity(0.1)).frame(width: 36, height: 12)
                    Capsule().fill(Color.white.opacity(0.08)).frame(width: 24, height: 8)
                }
            }
        }
        .frame(width: size, height: size)
        .overlay {
            if isHighlighted {
                Circle().stroke(Color.white.opacity(0.45), lineWidth: 1).padding(-2)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            window.map { CapacitySpeech.window($0, at: now) }
                ?? missingLabel.map { "\(Localization.windowLabel($0)): \(L("No data"))" }
                ?? placeholder
        )
    }

    private var trackColour: Color {
        guard let window, window.isUsedUp else { return SurfaceType.trackColour }
        return SurfaceType.red.opacity(0.22)
    }

    /// The arc from the lower left, clockwise over the top, `fraction` of
    /// the way to the lower right.
    private func arc(to fraction: Double) -> some Shape {
        Circle()
            .inset(by: lineWidth / 2)
            .trim(from: 0, to: 0.75 * min(max(fraction, 0), 1))
            .rotation(.degrees(135))
    }

    private func resetText(_ window: QuotaWindow) -> String {
        // Reset and not used since, as far as the Provider has said: when,
        // as a time alone like every other gap; the wide card says more.
        if let back = window.cameBackAt {
            return back.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Localization.current.locale))
        }
        return switch GaugeReset(resetsAt: window.resetsAt, at: now) {
        case let .at(date):
            date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Localization.current.locale))
        case let .in(countdown):
            countdown
        case .unknown:
            "—"
        }
    }
}

private extension QuotaWindow {
    /// Nothing left, as the gauge's number shows it: a sliver under half a
    /// percent reads "0%", so it is drawn as used up too.
    var isUsedUp: Bool { remainingPercentage <= 0 }
}

/// Beside a wide card's gauge: the window's name, how much is used, and how
/// long until it comes back — what the gauge itself has no room for.
private struct WideGaugeDetail: View {
    let window: QuotaWindow
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Localization.windowLabel(window.label))
                .font(SurfaceType.geist(13))
                .foregroundStyle(Color.white.opacity(0.75))
            Text(L("%d%% used", Int((window.usedFraction * 100).rounded())))
            if let back = window.cameBackAt {
                Text(L("reset %@", back.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Localization.current.locale))))
            } else if let resetsAt = window.resetsAt {
                Text(L("resets in %@", ResetCountdown.text(until: resetsAt, at: now)))
            }
        }
        .font(SurfaceType.caption)
        .foregroundStyle(SurfaceType.captionColour)
        .lineLimit(1)
        .accessibilityHidden(true)
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
            ProviderPresentation(displayName: spokenName, tint: .white)
        case .claudeCode:
            ProviderPresentation(displayName: spokenName, tint: SurfaceType.orange)
        case .openCode:
            ProviderPresentation(displayName: spokenName, tint: .white)
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
            // A dash, not a word, beside a Connect button; a Provider that
            // needs a person first says "No data" instead (ProviderCard).
            ConnectionStatePresentation(label: "—", tint: SurfaceType.red)
        }
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
