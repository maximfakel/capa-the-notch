// The Music Module's small drawn things: the transport glyphs and the
// speaker, the music note (the idle page's, before anything has played), and
// the seven decorative bars. Each is drawn at the size SwiftUI's SF Symbols
// would be at that point size.

import {EQUALIZER} from './music-layout.js';

const tri = (cr, x0, y0, x1, y1, x2, y2) => {
    cr.moveTo(x0, y0);
    cr.lineTo(x1, y1);
    cr.lineTo(x2, y2);
    cr.closePath();
};

/** A filled shape with softened corners: fill, then stroke the same path round-joined. */
function soft(g, size, color, path) {
    g.color(color);
    g.cr.setLineJoin(1);
    g.cr.setLineWidth(size * 0.14);
    g.cr.newPath();
    path(g.cr);
    g.cr.fill();
    g.cr.newPath();
    path(g.cr);
    g.cr.stroke();
}

/** `backward.fill`, `forward.fill`, `play.fill`, `pause.fill`, centred on (cx, cy), `size` points. */
export function drawTransport(g, kind, cx, cy, size, color) {
    const h = size * 0.74;
    switch (kind) {
    case 'play': {
        const w = size * 0.74;
        soft(g, size, color, cr => tri(cr, cx - w / 2 + size * 0.04, cy - h / 2, cx + w / 2 + size * 0.04, cy, cx - w / 2 + size * 0.04, cy + h / 2));
        break;
    }
    case 'pause': {
        const bar = size * 0.26, gap = size * 0.2;
        for (const x of [cx - gap / 2 - bar, cx + gap / 2])
            g.fillRoundRect(x, cy - h / 2, bar, h, size * 0.06, color);
        break;
    }
    case 'backward': {
        const w = size * 0.6;
        soft(g, size, color, cr => {
            tri(cr, cx - 0.02 * size, cy - h / 2, cx - 0.02 * size, cy + h / 2, cx - 0.02 * size - w, cy);
            tri(cr, cx + w - 0.02 * size, cy - h / 2, cx + w - 0.02 * size, cy + h / 2, cx - 0.02 * size, cy);
        });
        break;
    }
    case 'forward': {
        const w = size * 0.6;
        soft(g, size, color, cr => {
            tri(cr, cx + 0.02 * size, cy - h / 2, cx + 0.02 * size, cy + h / 2, cx + 0.02 * size + w, cy);
            tri(cr, cx - w + 0.02 * size, cy - h / 2, cx - w + 0.02 * size, cy + h / 2, cx + 0.02 * size, cy);
        });
        break;
    }
    default:
        break;
}
}

/** `speaker.slash.fill`, `speaker.wave.1.fill`, `speaker.wave.2.fill` at `size` points, centred. */
export function drawSpeaker(g, icon, cx, cy, size, color) {
    const k = size / 13;
    const x0 = cx - 6.5 * k;
    g.color(color);
    const cr = g.cr;
    cr.setLineJoin(1);
    cr.newPath();
    cr.moveTo(x0, cy - 2.6 * k);
    cr.lineTo(x0 + 2.8 * k, cy - 2.6 * k);
    cr.lineTo(x0 + 6.4 * k, cy - 5.6 * k);
    cr.lineTo(x0 + 6.4 * k, cy + 5.6 * k);
    cr.lineTo(x0 + 2.8 * k, cy + 2.6 * k);
    cr.lineTo(x0, cy + 2.6 * k);
    cr.closePath();
    cr.fill();
    if (icon === 'slash') {
        g.color(color);
        cr.setLineWidth(1.5 * k);
        cr.setLineCap(1);
        cr.newPath();
        cr.moveTo(x0 + 8.6 * k, cy - 3.4 * k);
        cr.lineTo(x0 + 13 * k, cy + 3.4 * k);
        cr.stroke();
        return;
    }
    cr.setLineWidth(1.4 * k);
    cr.setLineCap(1);
    const waves = icon === 'wave2' ? [3.2, 6.2] : [3.2];
    for (const r of waves) {
        cr.newPath();
        cr.arc(x0 + 6.8 * k, cy, r * k, -0.72, 0.72);
        cr.stroke();
    }
}

/** `music.note` at `size` points, centred: a filled eighth note. */
export function drawNote(g, cx, cy, size, color) {
    const cr = g.cr;
    g.color(color);
    const hx = cx - 0.14 * size, hy = cy + 0.3 * size, r = 0.17 * size;
    cr.newPath();
    cr.moveTo(hx + r, hy);
    cr.arc(hx, hy, r, 0, 2 * Math.PI);
    cr.closePath();
    cr.fill();
    const sx = hx + r - 0.035 * size, top = cy - 0.4 * size;
    g.fillRoundRect(sx - 0.035 * size, top, 0.07 * size, hy - top, 0.03 * size, color);
    cr.newPath();
    cr.moveTo(sx, top);
    cr.curveTo(sx + 0.05 * size, top + 0.1 * size, sx + 0.32 * size, top + 0.12 * size, sx + 0.28 * size, top + 0.4 * size);
    cr.curveTo(sx + 0.26 * size, top + 0.22 * size, sx + 0.12 * size, top + 0.2 * size, sx, top + 0.2 * size);
    cr.closePath();
    cr.fill();
}

/** The curve the bars move on: Core Animation's `easeInEaseOut`, cubic-bezier(0.42, 0, 0.58, 1). */
export function easeInEaseOut(x) {
    const [x1, y1, x2, y2] = [0.42, 0, 0.58, 1];
    const bez = (a, b, t) => 3 * a * t * (1 - t) ** 2 + 3 * b * t * t * (1 - t) + t ** 3;
    let lo = 0, hi = 1;
    for (let i = 0; i < 24; i++) {
        const mid = (lo + hi) / 2;
        if (bez(x1, x2, mid) < x)
            lo = mid;
        else
            hi = mid;
    }
    return bez(y1, y2, (lo + hi) / 2);
}

/**
 * Seven bars, as drawn. Decorative: while the track plays each one moves to a
 * new height of its own every 0.3 seconds, so the bars never fall into a
 * rhythm; paused they sink to four-point dashes; under Reduce Motion they
 * hold still. No audio is captured.
 */
export class Bars {
    constructor(height, seed = 1) {
        this.height = height;
        this.state = seed >>> 0 || 1;
        const rest = EQUALIZER.rest / height;
        this.from = Array(EQUALIZER.count).fill(rest);
        this.to = Array(EQUALIZER.count).fill(rest);
        this.begin = -Infinity;
        this.resting = null;
        this.moving = false;
    }

    random() {
        // xorshift32: enough for decoration, and the same stream anywhere.
        let x = this.state;
        x ^= x << 13; x >>>= 0;
        x ^= x >>> 17;
        x ^= x << 5; x >>>= 0;
        this.state = x;
        return x / 0x1_0000_0000;
    }

    scales(now) {
        const progress = Math.min(Math.max((now - this.begin) / EQUALIZER.beat, 0), 1);
        const e = easeInEaseOut(progress);
        return this.from.map((f, i) => f + (this.to[i] - f) * e);
    }

    retarget(now, to) {
        this.from = this.scales(now);
        this.to = to;
        this.begin = now;
    }

    /** Moves the bars to where they are at `now` (seconds). Returns whether they are still moving. */
    step(now, {playing, still = false}) {
        const rest = EQUALIZER.rest / this.height;
        const moving = playing && !still;
        const resting = !playing;
        const wasMoving = this.moving;
        if (resting !== this.resting) {
            this.resting = resting;
            if (resting)
                this.retarget(now, Array(EQUALIZER.count).fill(rest));
            else if (!moving)
                this.retarget(now, this.to.map(() => EQUALIZER.minScale + (1 - EQUALIZER.minScale) * this.random()));
        }
        // Set moving, they rise at once (`start()` steps before its timer), even
        // within a beat of the pause that sank them.
        if (moving && (!wasMoving || now - this.begin >= EQUALIZER.beat))
            this.retarget(now, this.to.map(() => EQUALIZER.minScale + (1 - EQUALIZER.minScale) * this.random()));
        this.moving = moving;
        return moving || now - this.begin < EQUALIZER.beat;
    }

    /**
     * Each bar as Core Animation draws it: a full-height layer with a corner
     * radius of 1, scaled about its middle — so the corners are scaled with
     * it, 1 across and `scale` tall.
     */
    draw(g, x, y, now) {
        const scales = this.scales(now);
        const cr = g.cr;
        scales.forEach((s, i) => {
            cr.save();
            cr.translate(x + i * EQUALIZER.pitch, y + this.height / 2);
            cr.scale(1, s);
            // A CALayer's `cornerRadius`: circular corners, not SwiftUI's continuous ones.
            g.fillRoundRect(0, -this.height / 2, EQUALIZER.barWidth, this.height, 1, [1, 1, 1, EQUALIZER.alpha], {circular: true});
            cr.restore();
        });
    }
}
