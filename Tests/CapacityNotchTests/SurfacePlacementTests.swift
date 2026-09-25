import CapacityNotchCore
import Foundation

private let builtIn = DisplayDescriptor(id: 1, name: "Built-in Retina", isBuiltIn: true)
private let external = DisplayDescriptor(id: 2, name: "Studio Display", isBuiltIn: false)
private let another = DisplayDescriptor(id: 3, name: "Projector", isBuiltIn: false)

func theBuiltInDisplayIsTheDefaultAndOneIsAlwaysChosen() throws {
    try expect(
        DisplaySelection.chosen(preferred: nil, available: [external, builtIn]) == builtIn,
        "With no preference the built-in display holds the surface"
    )
    try expect(
        DisplaySelection.chosen(preferred: external.id, available: [builtIn, external]) == external,
        "A preference that is connected is honoured"
    )
    try expect(
        DisplaySelection.chosen(preferred: nil, available: [external, another]) == external,
        "With no built-in display, the first connected one holds it"
    )
    try expect(
        DisplaySelection.chosen(preferred: nil, available: []) == nil,
        "With no display at all there is nowhere to put it"
    )
}

func aDisplayThatIsUnpluggedDoesNotStrandTheSurface() throws {
    let chosen = DisplaySelection.chosen(preferred: external.id, available: [builtIn])

    try expect(
        chosen == builtIn,
        "A preferred display that is gone gives way to one that is here, got \(chosen?.name ?? "nothing")"
    )
}

func aPinnedSurfaceStaysUntilItIsDismissed() throws {
    let store = CapacityNotchStore(snapshots: UnreadCapacity.snapshots())

    try expect(!store.isPinned, "It starts unpinned")

    store.pin()
    try expect(store.isPinned, "A click pins it")
    try expect(store.presentation == .expanded, "And opens it")

    store.collapse()
    try expect(
        store.presentation == .compact,
        "A pointer leaving can still close it — the panel is what declines to"
    )

    store.pin()
    store.togglePin()
    try expect(!store.isPinned, "A second click lets it go")
    try expect(store.presentation == .compact, "And closes it")

    store.pin()
    store.dismiss()
    try expect(!store.isPinned, "Escape and a click elsewhere dismiss it the same way")
    try expect(store.presentation == .compact, "And close it")
}

// The windows below were read off this machine (a 2056 × 1329 display with a
// 38-point camera housing): a test window taken fullscreen, then back.
private let display = CGRect(x: 0, y: 0, width: 2056, height: 1329)
private let iconLevel = -2_147_483_603
private let menuBar = [
    ScreenWindow(level: 24, owner: "Window Server", bounds: CGRect(x: 0, y: 0, width: 2056, height: 39)),
    ScreenWindow(level: -2_147_483_624, owner: "Dock", bounds: display),
    ScreenWindow(level: -2_147_483_626, owner: "Window Server", bounds: display),
]
private let desktop = [
    ScreenWindow(level: -2_147_483_603, owner: "Finder", bounds: display),
    ScreenWindow(level: -2_147_483_625, owner: "Обои", bounds: display),
]

func aFullscreenApplicationIsToldApartFromAZoomedWindow() throws {
    let fullscreen = menuBar + [
        ScreenWindow(level: 0, owner: "Safari", bounds: CGRect(x: 0, y: 39, width: 2056, height: 1290)),
        ScreenWindow(level: -2_147_483_622, owner: "Dock", bounds: display),
    ]
    try expect(
        FullscreenDetection.isFullscreen(windows: fullscreen, screen: display, menuBarHeight: 38, desktopIconLevel: iconLevel),
        "A window spanning the display under the camera, with no desktop behind it, is fullscreen"
    )

    let zoomed = menuBar + desktop + [
        ScreenWindow(level: 0, owner: "Safari", bounds: CGRect(x: 0, y: 39, width: 2056, height: 1290)),
    ]
    try expect(
        !FullscreenDetection.isFullscreen(windows: zoomed, screen: display, menuBarHeight: 38, desktopIconLevel: iconLevel),
        "The same window over the wallpaper is only zoomed"
    )

    let ordinary = menuBar + desktop + [
        ScreenWindow(level: 0, owner: "Telegram", bounds: CGRect(x: 1427, y: 70, width: 509, height: 1053)),
    ]
    try expect(
        !FullscreenDetection.isFullscreen(windows: ordinary, screen: display, menuBarHeight: 38, desktopIconLevel: iconLevel),
        "An ordinary Space is not fullscreen"
    )

    // Chrome, fullscreen: the tab strip, the toolbar and the page are
    // separate windows, read off this machine and moved to the display's
    // origin. None of them spans the display alone.
    let chrome = menuBar + [
        ScreenWindow(level: 0, owner: "Google Chrome", bounds: CGRect(x: 0, y: 39, width: 2056, height: 41)),
        ScreenWindow(level: 0, owner: "Google Chrome", bounds: CGRect(x: 0, y: 80, width: 2056, height: 81)),
        ScreenWindow(level: 0, owner: "Google Chrome", bounds: CGRect(x: 0, y: 39, width: 2056, height: 158)),
        ScreenWindow(level: 0, owner: "Google Chrome", bounds: CGRect(x: 0, y: 161, width: 2056, height: 1168)),
        ScreenWindow(level: -2_147_483_622, owner: "Dock", bounds: display),
    ]
    try expect(
        FullscreenDetection.isFullscreen(windows: chrome, screen: display, menuBarHeight: 38, desktopIconLevel: iconLevel),
        "Chrome's stacked windows together span the display, so Chrome is fullscreen"
    )

    let apart = menuBar + [
        ScreenWindow(level: 0, owner: "Google Chrome", bounds: CGRect(x: 0, y: 39, width: 2056, height: 41)),
        ScreenWindow(level: 0, owner: "Google Chrome", bounds: CGRect(x: 0, y: 400, width: 2056, height: 929)),
    ]
    try expect(
        !FullscreenDetection.isFullscreen(windows: apart, screen: display, menuBarHeight: 38, desktopIconLevel: iconLevel),
        "Windows with a gap between them do not span the display"
    )

    let elsewhere = CGRect(x: 2056, y: 0, width: 1920, height: 1080)
    try expect(
        !FullscreenDetection.isFullscreen(windows: fullscreen, screen: elsewhere, menuBarHeight: 24, desktopIconLevel: iconLevel),
        "A fullscreen application on another display leaves this one alone"
    )
}

// Read off this machine on macOS 27.0: the desktop-level windows the Dock held
// on 26.6 now belong to WindowManager, in fullscreen Spaces and ordinary ones.
func onMacOS27WindowManagerHoldsWhatTheDockHeld() throws {
    let base = [
        ScreenWindow(level: 24, owner: "Window Server", bounds: CGRect(x: 0, y: 0, width: 2056, height: 39)),
        ScreenWindow(level: -2_147_483_624, owner: "WindowManager", bounds: display),
        ScreenWindow(level: -2_147_483_626, owner: "Window Server", bounds: display),
    ]
    let chrome = base + [
        ScreenWindow(level: 0, owner: "Google Chrome", bounds: CGRect(x: 0, y: 39, width: 2056, height: 41)),
        ScreenWindow(level: 0, owner: "Google Chrome", bounds: CGRect(x: 0, y: 80, width: 2056, height: 81)),
        ScreenWindow(level: 0, owner: "Google Chrome", bounds: CGRect(x: 0, y: 39, width: 2056, height: 158)),
        ScreenWindow(level: 0, owner: "Google Chrome", bounds: CGRect(x: 0, y: 161, width: 2056, height: 1168)),
        ScreenWindow(level: -2_147_483_622, owner: "WindowManager", bounds: display),
    ]
    try expect(
        FullscreenDetection.isFullscreen(windows: chrome, screen: display, menuBarHeight: 38, desktopIconLevel: iconLevel),
        "Fullscreen Chrome on macOS 27 is fullscreen"
    )

    let figma = base + [
        ScreenWindow(level: 0, owner: "Figma Beta", bounds: CGRect(x: 0, y: 39, width: 2056, height: 32)),
        ScreenWindow(level: 0, owner: "Figma Beta", bounds: CGRect(x: 0, y: 39, width: 2056, height: 1290)),
        ScreenWindow(level: -2_147_483_622, owner: "WindowManager", bounds: display),
    ]
    try expect(
        FullscreenDetection.isFullscreen(windows: figma, screen: display, menuBarHeight: 38, desktopIconLevel: iconLevel),
        "Fullscreen Figma on macOS 27 is fullscreen"
    )

    let zoomed = base + desktop + [
        ScreenWindow(level: 0, owner: "Figma Beta", bounds: CGRect(x: 0, y: 39, width: 2056, height: 1290)),
    ]
    try expect(
        !FullscreenDetection.isFullscreen(windows: zoomed, screen: display, menuBarHeight: 38, desktopIconLevel: iconLevel),
        "A spanning window over the wallpaper on macOS 27 is only zoomed"
    )
}

// Read off this machine on macOS 27.0 at 20 Hz: changing Space slides the
// windows sideways, and the slide eases out over half a second, a point or two
// at a time. The desktop leaves the window list partway through.
private func figma(at x: CGFloat) -> [ScreenWindow] {
    [
        ScreenWindow(level: 0, owner: "Figma Beta", bounds: CGRect(x: x, y: 39, width: 2056, height: 32)),
        ScreenWindow(level: 0, owner: "Figma Beta", bounds: CGRect(x: x, y: 39, width: 2056, height: 1290)),
    ]
}

private func chrome(at x: CGFloat) -> [ScreenWindow] {
    [
        ScreenWindow(level: 0, owner: "Google Chrome", bounds: CGRect(x: x, y: 39, width: 2056, height: 41)),
        ScreenWindow(level: 0, owner: "Google Chrome", bounds: CGRect(x: x, y: 80, width: 2056, height: 81)),
        ScreenWindow(level: 0, owner: "Google Chrome", bounds: CGRect(x: x, y: 39, width: 2056, height: 158)),
        ScreenWindow(level: 0, owner: "Google Chrome", bounds: CGRect(x: x, y: 161, width: 2056, height: 1168)),
    ]
}

private let fullscreenSpace = [
    ScreenWindow(level: 24, owner: "Window Server", bounds: CGRect(x: 0, y: 0, width: 2056, height: 39)),
    ScreenWindow(level: -2_147_483_624, owner: "WindowManager", bounds: display),
    ScreenWindow(level: -2_147_483_622, owner: "WindowManager", bounds: display),
    ScreenWindow(level: -2_147_483_626, owner: "Window Server", bounds: display),
]

private let telegram = ScreenWindow(level: 0, owner: "Telegram", bounds: CGRect(x: 565, y: 146, width: 509, height: 1053))

private func verdicts(_ frames: [[ScreenWindow]]) -> [Bool] {
    frames.map {
        FullscreenDetection.isFullscreen(windows: $0, screen: display, menuBarHeight: 38, desktopIconLevel: iconLevel)
    }
}

func aSlideBetweenFullscreenSpacesStaysFullscreen() throws {
    let frames = [2033, 1442, 989, 623, 390, 163, 102].map { fullscreenSpace + chrome(at: $0 - 2120) + figma(at: $0) }
        + [64, 43, 27, 17, 10, 7, 4, 3, 2, 1, 0].map { fullscreenSpace + figma(at: $0) }
    let seen = verdicts(frames)
    try expect(!seen.contains(false), "From fullscreen Chrome to fullscreen Figma, every frame is fullscreen: \(seen)")
}

// The desktop slides too: the wallpaper and the icons leave with the Space
// they belong to, and stand at the display's origin only once it has settled.
private func desktop(at x: CGFloat) -> [ScreenWindow] {
    [
        ScreenWindow(level: -2_147_483_603, owner: "Finder", bounds: display.offsetBy(dx: x, dy: 0)),
        ScreenWindow(level: -2_147_483_625, owner: "Обои", bounds: display.offsetBy(dx: x, dy: 0)),
    ]
}

private func finderWindow(_ x: CGFloat) -> ScreenWindow {
    ScreenWindow(level: 0, owner: "Finder", bounds: CGRect(x: x, y: 270, width: 1099, height: 711))
}

func enteringFullscreenIsToldFromTheFirstFrame() throws {
    // Desktop to fullscreen Chrome, frame by frame.
    let frames = [(1898, -222, 589), (1339, -781, 30), (856, -1264, -453), (538, -1582, -771), (210, -1910, -1300), (82, -2038, -1300)]
        .map { chromeX, desktopX, finderX in
            fullscreenSpace + desktop(at: CGFloat(desktopX)) + chrome(at: CGFloat(chromeX)) + [finderWindow(CGFloat(finderX))]
        }
        + [55, 13, 2, 0].map { fullscreenSpace + chrome(at: $0) }
    let seen = verdicts(frames)
    try expect(!seen.contains(false), "From the first frame of the slide, Chrome arriving is fullscreen: \(seen)")
}

func leavingFullscreenIsToldOnceTheApplicationHasGone() throws {
    // Fullscreen Chrome back to the desktop.
    let whileChromeShows = verdicts([(278, -1842), (1261, -859), (1979, -141)].map { chromeX, desktopX in
        fullscreenSpace + desktop(at: CGFloat(desktopX)) + chrome(at: CGFloat(chromeX)) + [finderWindow(CGFloat(desktopX) + 811)]
    })
    try expect(!whileChromeShows.contains(false), "While Chrome is still sliding out, it is still fullscreen: \(whileChromeShows)")

    let once = verdicts([-55, -13, -1, 0].map { fullscreenSpace + desktop(at: $0) + [finderWindow($0 + 811)] })
    try expect(!once.contains(true), "Once Chrome has gone, it is not fullscreen: \(once)")
}

func aZoomedWindowOverASettledDesktopIsNotFullscreen() throws {
    let zoomed = fullscreenSpace + desktop(at: 0) + chrome(at: 0)
    try expect(!verdicts([zoomed])[0], "Chrome's windows over a desktop at rest are only zoomed")
}
