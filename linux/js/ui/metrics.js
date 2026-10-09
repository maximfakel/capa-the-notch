// The numbers the Swift surface is built from, in one place. Where a number
// has a comment in the Swift, its comment is here too.

export const Metrics = {
    /** The room every open page has under the strip. */
    pageHeight: 152,
    /** The page dots, at rest: eight, with four above and eight below. */
    switcherHeight: 20,
    /** How much taller the switcher stands with buttons than with dots. */
    switcherGrowth: 14,
    minimumSurfaceWidth: 560,
    /** The room every page leaves between its content and the surface's sides. */
    pageMargin: 18,
    compactRadius: 22,
    openRadius: 38,
    shoulder: 20,
    /** How close the pointer comes before the closed surface grows, and by how much. */
    nearDistance: 60,
    nearGrowth: {width: 10, height: 4},
    /** Closed, the strip's sides stand this far from the shape's edge; open or wide, this far. */
    stripInsetCompact: 12,
    stripInsetOpen: 18,
    /** The pointer is read this often; it must settle three beats to open and be gone two to close. */
    pointerInterval: 0.1,
    presentTicksBeforeOpen: 3,
    absentTicksBeforeClose: 2,
    /** How close to the open surface's bottom edge the pointer comes before the dots become buttons. */
    switcherReach: 40,
    switcherLeaves: 58,
    /** Past this many points a swipe turns the page. */
    swipeTurn: 40,
    /** Both cards the same size; the card and its gauges. */
    cardRadius: 20,
    cardPadding: 14,
    headerRow: 22,
    gaugeSize: 88,
    gaugeLine: 7,
};

/** Geist's own line: ascent 1005, descent 295 of 1000. */
export const GEIST = {ascent: 1.005, descent: 0.295, lineHeight: 1.3};

export const Colors = {
    green: [0x30 / 255, 0xD1 / 255, 0x58 / 255],
    yellow: [1, 0xD6 / 255, 0x0A / 255],
    red: [1, 0x45 / 255, 0x3A / 255],
    orange: [1, 0x9F / 255, 0x0A / 255],
    white: [1, 1, 1],
    black: [0, 0, 0],
    caption: [1, 1, 1, 0x8C / 255],
    track: [1, 1, 1, 0x26 / 255],
    card: [1, 1, 1, 0x14 / 255],
    connect: [1, 1, 1, 0x33 / 255],
};

/** The type the surface is drawn at (`SurfaceType`). */
export const Type = {
    providerName: {size: 17, weight: 600},
    statusChip: {size: 11, weight: 600, family: 'system'},
    windowLabel: {size: 15, weight: 500},
    compactCapacity: {size: 15, weight: 500, tabular: true},
    caption: {size: 11, weight: 400},
    guidance: {size: 15, weight: 400},
    refreshGlyph: {size: 17, weight: 600, family: 'system'},
    geist: (size, weight = 400) => ({size, weight}),
};
