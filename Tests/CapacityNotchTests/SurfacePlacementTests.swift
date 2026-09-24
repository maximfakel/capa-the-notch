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
