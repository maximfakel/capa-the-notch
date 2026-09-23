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

func hidingPutsTheSurfaceAwayAndBringsItBack() throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let hide = SurfaceHide(from: now)

    try expect(!hide.isOver(at: now), "It has only just been put away")
    try expect(
        !hide.isOver(at: now.addingTimeInterval(3599)),
        "A second short of the hour it is still away"
    )
    try expect(
        hide.isOver(at: now.addingTimeInterval(3600)),
        "At the hour it comes back on its own"
    )
    try expect(
        hide.remainingText(at: now.addingTimeInterval(1800)) == "30m",
        "The menu can say how long is left, got \(hide.remainingText(at: now.addingTimeInterval(1800)))"
    )
    try expect(
        hide.remainingText(at: now.addingTimeInterval(7200)) == "moments",
        "Past the hour there is nothing left to wait for"
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
