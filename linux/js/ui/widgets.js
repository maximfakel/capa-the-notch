// The small things the pages share: paragraphs that give out after a number
// of lines, the capsule button, the refresh glyph, the gauge. Each is drawn at
// explicit coordinates taken from the Swift view that has it.

import {Colors, Metrics, Type} from './metrics.js';
import {GAUGE_START} from './gauge-geometry.js';
import {languageClock} from './format.js';
import {t} from './strings.js';

/**
 * How a plain button looks held down: the system dims its label while it is
 * pressed, and does nothing on hover (`.buttonStyle(.plain)`).
 */
export const PRESSED_OPACITY = 0.6;

/** Whether the scene says the button `id` is held down now; a scene that does not track presses never is. */
export function isPressed(scene, id) {
    return !!scene.isPressed?.(id);
}

/** How long until `resetsAt` (unix seconds), in the fewest words that stay honest (`ResetCountdown`). */
export function resetCountdown(resetsAt, now) {
    const remaining = Math.round(resetsAt - now);
    if (remaining <= 0)
        return t('moments');
    const hours = Math.floor(remaining / 3600);
    const minutes = Math.floor((remaining % 3600) / 60);
    if (hours >= 24) {
        const days = Math.floor(hours / 24), spare = hours % 24;
        return spare > 0 ? t('%dd %dh', days, spare) : t('%dd', days);
    }
    if (hours > 0)
        return minutes > 0 ? t('%dh %dm', hours, minutes) : t('%dh', hours);
    return remaining >= 60 ? t('%dm', minutes) : t('under a minute');
}

/**
 * What a gauge writes in its gap (`GaugeReset`): the time of day the window
 * comes back while that is within a day, how long until it once it is
 * further off, and a dash when the Provider did not say. The time is in the
 * language's own clock, not the desktop's, as Swift gives it the app's locale.
 */
export function gaugeResetText(resetsAt, now) {
    if (resetsAt == null)
        return '—';
    const remaining = resetsAt - now;
    return remaining > 0 && remaining < 24 * 3600 ? languageClock(resetsAt) : resetCountdown(resetsAt, now);
}

/** Splits `str` into at most `maxLines` lines no wider than `maxWidth`, the last ending in an ellipsis if it had to be cut. */
export function wrapLines(g, str, font, maxWidth, maxLines) {
    const words = String(str).split(/\s+/).filter(Boolean);
    const lines = [];
    let line = '';
    let i = 0;
    for (; i < words.length; i++) {
        const trial = line ? `${line} ${words[i]}` : words[i];
        if (g.measureText(trial, font) <= maxWidth || !line) {
            line = trial;
            continue;
        }
        if (lines.length === maxLines - 1)
            break;
        lines.push(line);
        line = words[i];
    }
    if (i < words.length) {
        // Ran out of lines: the rest goes into the last one, which gives out.
        line = [line, ...words.slice(i)].join(' ');
    }
    if (line)
        lines.push(line);
    return lines.slice(0, maxLines);
}

/** A paragraph of at most `maxLines` lines. Returns its height. */
export function drawParagraph(g, str, x, y, font, color, maxWidth, maxLines) {
    const lines = wrapLines(g, str, font, maxWidth, maxLines);
    const lh = g.lineHeight(font);
    lines.forEach((line, n) => {
        // Only the last may be cut, and then it ends in an ellipsis.
        const last = n === lines.length - 1;
        g.drawText(line, x, y + n * lh, font, color, {maxWidth: last ? maxWidth : null});
    });
    return lines.length * lh;
}

/** How wide `capsuleButton` draws `title` with `inset` either side. */
export function capsuleWidth(g, title, inset) {
    return g.measureText(title, Type.windowLabel) + inset * 2;
}

/**
 * The surface's one kind of button: a word on a pale capsule. `inset` is
 * either side of the word. Returns its size, and registers `onClick`; `hit`
 * adds to what is registered (what a screen reader calls it, the keyboard).
 */
export function capsuleButton(g, scene, id, title, x, y, inset, onClick, hit = {}) {
    const font = Type.windowLabel;
    const w = capsuleWidth(g, title, inset);
    const h = 18 + 20;
    // A plain button: no hover of its own, only dimmed while held down, the
    // capsule and its word as one picture.
    g.group(isPressed(scene, id) ? PRESSED_OPACITY : 1, () => {
        g.fillRoundRect(x, y, w, h, h / 2, Colors.connect);
        g.drawText(title, x + inset, y + 10 + (18 - g.lineHeight(font)) / 2, font, Colors.white);
    });
    scene.addHit({id, x, y, w, h, onClick, cursor: 'pointer', label: title, radius: h / 2, ...hit});
    return {w, h};
}

/**
 * The arrow.clockwise glyph the refresh button carries, centred at (cx, cy):
 * most of a circle open at the upper right, ending at the top in an arrowhead
 * that points the way round.
 */
export function refreshGlyph(g, cx, cy, color) {
    const r = 5.6;
    const cr = g.cr;
    const ox = cx, oy = cy + 0.4;
    const start = (-18 * Math.PI) / 180, end = (258 * Math.PI) / 180;
    g.color(color);
    cr.setLineWidth(1.9);
    cr.setLineCap(1);
    cr.newPath();
    cr.arc(ox, oy, r, start, end);
    cr.stroke();
    // The head: its tip on along the tangent, its base across the circle's radius.
    const ex = ox + r * Math.cos(end), ey = oy + r * Math.sin(end);
    const tx = -Math.sin(end), ty = Math.cos(end);
    const nx = Math.cos(end), ny = Math.sin(end);
    cr.newPath();
    cr.moveTo(ex + tx * 4.6, ey + ty * 4.6);
    cr.lineTo(ex + nx * 3.4 - tx * 0.6, ey + ny * 3.4 - ty * 0.6);
    cr.lineTo(ex - nx * 3.4 - tx * 0.6, ey - ny * 3.4 - ty * 0.6);
    cr.closePath();
    cr.fill();
}

/** The notch's pace dot: six points of colour, whatever the state. */
export function paceDot(g, cx, cy, color) {
    g.fillCircle(cx, cy, 3, color);
}

const lerp = (a, b, t) => a + (b - a) * t;
export {lerp};

/**
 * One Quota Window as an open arc: 270°, opening downwards, filled from the
 * lower left to what is left, the share in the middle, the window under it,
 * and when it comes back in the gap. `window` null is a window not read yet:
 * an empty arc and two quiet bars where the numbers will be. `now` (unix
 * seconds) is when the gap's words are worked out for (`TimelineView`).
 */
export function drawGauge(g, x, y, window, {showsLabel = true, highlighted = false, now = Date.now() / 1000} = {}) {
    const size = Metrics.gaugeSize, line = Metrics.gaugeLine;
    const cx = x + size / 2, cy = y + size / 2;
    const r = size / 2 - line / 2;
    const used = window && window.remainingPercentage <= 0;
    const paceColor = window ? {sustainable: Colors.green, tightening: Colors.yellow, unsustainable: Colors.red}[window.pace] : null;

    g.strokeArc(cx, cy, r, GAUGE_START, GAUGE_START + 1.5 * Math.PI, used ? [...Colors.red, 0.22] : Colors.track, line);
    if (window && !used) {
        const fraction = Math.min(Math.max(window.remainingFraction, 0), 1);
        g.strokeArc(cx, cy, r, GAUGE_START, GAUGE_START + 1.5 * Math.PI * fraction, paceColor, line);
    }

    if (!window) {
        // Two bars where the number and the label will be: a 12 and an 8 high with six between, centred.
        g.fillRoundRect(cx - 18, cy - 13, 36, 12, 6, [1, 1, 1, 0.1]);
        g.fillRoundRect(cx - 12, cy + 5, 24, 8, 4, [1, 1, 1, 0.08]);
    } else {
        // The number in tabular figures, so it does not shift as it changes (`.monospacedDigit()`).
        const numberFont = {...Type.geist(22, 600), tabular: true};
        const labelFont = Type.caption;
        const numberH = g.lineHeight(numberFont), labelH = g.lineHeight(labelFont);
        const total = numberH + (showsLabel ? labelH : 0);
        const top = cy - total / 2;
        g.drawText(`${Math.round(window.remainingPercentage)}%`, cx, top, numberFont, used ? Colors.red : Colors.white, {align: 'center'});
        // One line each, as wide as the gauge's 88 (`lineLimit(1)` in its frame).
        if (showsLabel)
            g.drawText(window.label, cx, top + numberH, labelFont, [1, 1, 1, 0.6], {align: 'center', maxWidth: size});
        const reset = gaugeResetText(window.resetsAt, now);
        g.drawText(reset, cx, y + size - g.lineHeight(Type.caption), Type.caption, used ? Colors.red : Colors.caption,
            {align: 'center', maxWidth: size});
    }
    if (highlighted)
        g.strokeCircle(cx, cy, size / 2 + 2, [1, 1, 1, 0.45], 1);
}
