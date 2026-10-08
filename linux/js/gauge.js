// What every surface draws the same way: the gauge's arc, the colours, and the
// small decisions of wording a view still leaves to the surface (a clock time
// in the person's own clock). Written against the Cairo drawing API; the web
// surface wraps its canvas to speak it (`cairo-canvas.js`).

export const GREEN = [0x30 / 255, 0xD1 / 255, 0x58 / 255];
export const YELLOW = [1, 0xD6 / 255, 0x0A / 255];
export const RED = [1, 0x45 / 255, 0x3A / 255];
export const CAPTION = [1, 1, 1, 0x8C / 255];
export const TRACK = [1, 1, 1, 0x26 / 255];

export const PACE = {sustainable: GREEN, tightening: YELLOW, unsustainable: RED};

export const GAUGE_SIZE = 88;
export const GAUGE_LINE = 7;

export const css = c => `rgba(${Math.round(c[0] * 255)},${Math.round(c[1] * 255)},${Math.round(c[2] * 255)},${c[3] ?? 1})`;
export const clamp01 = v => Math.min(Math.max(v, 0), 1);

/** Nothing left, as the gauge's number shows it: a sliver under half a percent reads 0%. */
export const isUsedUp = w => w.remainingPercentage <= 0;

/** The time of day a window comes back, in the person's own clock. */
export function timeOfDay(unixSeconds) {
    return new Date(unixSeconds * 1000).toLocaleTimeString([], {hour: 'numeric', minute: '2-digit'});
}

/** What a gauge writes in its gap. */
export function resetText(w) {
    switch (w.resetKind) {
    case 'at': return timeOfDay(w.resetsAt);
    case 'in': return w.resetIn;
    default: return '—';
    }
}

/**
 * One Quota Window as an open arc: 270°, opening downwards, filled from the
 * lower left to what is left. A window used up tints its whole track red.
 * `window` is null for a window not read yet: an empty arc.
 */
export function paintGauge(cr, width, height, window) {
    const r = Math.min(width, height) / 2 - GAUGE_LINE / 2;
    const start = 0.75 * Math.PI; // the lower left, clockwise over the top
    cr.setLineWidth(GAUGE_LINE);
    cr.setLineCap(1); // round
    const arc = fraction => cr.arc(width / 2, height / 2, r, start, start + 1.5 * Math.PI * clamp01(fraction));
    cr.setSourceRGBA(...(window && isUsedUp(window) ? [...RED, 0.22] : TRACK));
    arc(1);
    cr.stroke();
    if (window && !isUsedUp(window)) {
        cr.setSourceRGBA(...PACE[window.pace], 1);
        arc(window.remainingFraction);
        cr.stroke();
    }
}

/** What the card header's chip says, and in what colour. */
export function chipFor(view) {
    if (view.state === 'disconnected' && view.needsAPersonFirst)
        return {text: 'No data', color: RED};
    if (view.reasonRepeatsTheChip && view.state === 'fresh' && view.guidance) {
        // OpenCode's month used up stops work however green the windows are.
        return {text: 'Month used up', color: RED};
    }
    switch (view.state) {
    case 'mock': return {text: 'Mock', color: CAPTION};
    case 'connecting': return {text: 'Connecting', color: CAPTION};
    case 'fresh': return {text: 'Fresh', color: GREEN};
    case 'stale': return {text: 'Stale', color: YELLOW};
    default: return {text: '—', color: RED};
    }
}

/**
 * The closed strip's two figures. Two Providers: the first on the left, the
 * second on the right, each with its headline window. One Provider: its
 * five-hour window on the left, its week on the right. Each is `[view, window]`.
 */
export function stripPairs(connected) {
    const [a, b] = connected;
    if (!a)
        return [];
    const headline = v => v.windows.find(w => w.id === v.headline) ?? null;
    return b
        ? [[a, headline(a)], [b, headline(b)]]
        : [[a, a.windows[0] ?? null], [a, a.windows[1] ?? null]];
}
