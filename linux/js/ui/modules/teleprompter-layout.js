// The Teleprompter's numbers (`TeleprompterLayout` in Rust, from Paper
// "Notch — Compact — Teleprompter"), kept equal to the Rust by a test.
// Points. A size is 'small' | 'medium' | 'large'.

import {symbolWidth} from './music-layout.js';

export const ROW_WIDTH = 560;
export const CONTROLS_WIDTH = 15;
export const CONTROLS_GAP = 12;
export const TEXT_INSET = 18 + CONTROLS_WIDTH + CONTROLS_GAP;
export const TEXT_WIDTH = ROW_WIDTH - TEXT_INSET - 18;
export const LINE_GAP = 2;
export const TOP_INSET = 2;
export const BOTTOM_INSET = 16;
export const STRIP_GAP = 6;
export const VISIBLE_LINES = 3;
/** As tall as an open page and its dots, whatever the size. */
export const ROW_HEIGHT = 152 + 20;

export const POINTS = {small: 15, medium: 17, large: 20};

export const pointsOf = size => POINTS[size] ?? POINTS.medium;
export const lineHeight = size => Math.round(pointsOf(size) * 1.3);
export const pitch = size => lineHeight(size) + LINE_GAP;
export const kern = size => -0.01 * pointsOf(size);

/** Six lines at the smaller sizes, five at the largest: what the row's room holds. */
export function rowLines(size) {
    const room = ROW_HEIGHT - STRIP_GAP - TOP_INSET - BOTTOM_INSET + LINE_GAP;
    return Math.max(VISIBLE_LINES, Math.floor(room / pitch(size)));
}

/** The row's text area under the strip: its lines and their insets. */
export function textAreaHeight(size) {
    const n = rowLines(size);
    return TOP_INSET + n * lineHeight(size) + (n - 1) * LINE_GAP + BOTTOM_INSET;
}

/** The current line full white, the next at 55%, the one after at 25%, then quieter. */
export function lineOpacity(row) {
    if (row === 0) return 1;
    if (row === 1) return 0x8C / 255;
    if (row === 2) return 0x40 / 255;
    return Math.max((0x40 / 255) * 0.82 ** (row - 2), 0.1);
}

/** One band per line in view, in fractions of the text area's height. */
export function fadeBands(size) {
    const height = Math.max(textAreaHeight(size), 1);
    const lh = lineHeight(size), p = pitch(size), n = rowLines(size);
    return Array.from({length: n}, (_, line) => {
        const top = TOP_INSET + line * p;
        return {
            from: line === 0 ? 0 : top / height,
            to: line === n - 1 ? 1 : (top + lh) / height,
            opacity: lineOpacity(line),
        };
    });
}

/**
 * The fade as the row's mask has it (`ScriptScrollView.layoutFade`): two stops
 * a band, `[y, opacity]` in points down the text area, the brightness held
 * across a line and changing evenly within the two points between lines, as a
 * `CAGradientLayer` interpolates between its locations.
 */
export function fadeStops(size) {
    const height = Math.max(textAreaHeight(size), 1);
    const stops = [];
    for (const band of fadeBands(size))
        stops.push([band.from * height, band.opacity], [band.to * height, band.opacity]);
    return stops;
}

/** The fade's opacity at `y` points down the text area: held before the first stop and after the last. */
export function fadeOpacityAt(stops, y) {
    if (y <= stops[0][0])
        return stops[0][1];
    for (let i = 1; i < stops.length; i++) {
        const [y1, a1] = stops[i];
        if (y <= y1) {
            const [y0, a0] = stops[i - 1];
            return y1 > y0 ? a0 + (a1 - a0) * (y - y0) / (y1 - y0) : a1;
        }
    }
    return stops[stops.length - 1][1];
}

/** The lines worth drawing at a place: one before, a few after. */
export function linesToDraw(position, size, count) {
    if (count === 0)
        return null;
    const current = Math.max(Math.floor(position), 0);
    const first = Math.max(current - 1, 0);
    const last = Math.min(current + rowLines(size) + 3, count - 1);
    return first <= last ? [first, last] : null;
}

export const previewHeight = size => VISIBLE_LINES * lineHeight(size) + (VISIBLE_LINES - 1) * LINE_GAP;

/** Four points at the start, as drawn: where the Script is, even before it moves. */
export const progressFillWidth = (barWidth, fraction) => Math.max(barWidth * Math.min(Math.max(fraction, 0), 1), 4);

export const speedText = multiplier => `${multiplier.toFixed(2)}x`;

/**
 * The page's controls as wide as their SF Symbols are at a point size, so the
 * speed and Kapa stand where the `HStack`s put them: play.fill and pause.fill
 * as Music has them, stop.fill a square a little narrower, and minus and plus
 * as wide as each other (12.3 at 13 points).
 */
export const controlWidth = {
    play: symbolWidth.play,
    pause: symbolWidth.pause,
    stop: size => size * 0.86,
    minus: size => size * 0.946,
    plus: size => size * 0.946,
};

/** `mm:ss`. */
export function clockText(seconds) {
    const whole = Math.floor(Math.max(seconds, 0));
    return `${String(Math.floor(whole / 60)).padStart(2, '0')}:${String(whole % 60).padStart(2, '0')}`;
}

/**
 * Where the Script is at a wall-clock moment (ms), from the Module's state.
 * Not running, it is where it was put; running, it moves on from its anchor
 * after the start's hold, to the last line.
 */
export function positionAt(state, wallMs) {
    const p = state.playback;
    if (p.state !== 'running')
        return p.position;
    const m = state.motion;
    const dt = Math.max(0, wallMs - m.anchoredAtMs) / 1000;
    return Math.min(m.anchor + dt * m.linesPerSecond, m.lastLine);
}

/**
 * The moment a clock ticking every `stepMs` from the Script's anchor last
 * ticked: the page's `TimelineView(.periodic(by: 0.25))`, and the beat that
 * moves the Row a line at a time under Reduce Motion. Not running, now.
 */
export function steppedAt(state, wallMs, stepMs = 250) {
    if (state.playback?.state !== 'running')
        return wallMs;
    const from = state.motion?.anchoredAtMs ?? 0;
    return from + Math.floor((wallMs - from) / stepMs) * stepMs;
}

export function elapsedAt(state, wallMs) {
    const lps = state.motion.linesPerSecond;
    return lps > 0 ? positionAt(state, wallMs) / lps : 0;
}

export function progressAt(state, wallMs) {
    const last = state.motion.lastLine;
    return last > 0 ? positionAt(state, wallMs) / last : 0;
}
