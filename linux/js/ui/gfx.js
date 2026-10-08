// Drawing for the shared scene: a Cairo-style context for shapes, and a text
// backend for words, behind one small class. The GNOME extension supplies
// Cairo and Pango; the tests a recording backend.
//
// Text is placed by the TOP of its line box, as SwiftUI lays it out, so the
// coordinates in the pages are the ones the Swift rows imply.

import {GEIST} from './metrics.js';

const clamp = (v, lo, hi) => Math.min(Math.max(v, lo), hi);

/** How far along each side a continuous corner runs, in radii. */
const CONTINUOUS_RUN = 1.52866483;

/**
 * One continuous corner as three cubic curves, in radii: the start on the side
 * arriving, then each curve's two control points and its end. `[a, b]` is
 * how far back along the arriving side and how far along the leaving one.
 */
const CONTINUOUS = [
    [CONTINUOUS_RUN, 0],
    [1.08849323, 0], [0.86840701, 0], [0.63149399, 0.07491100],
    [0.37282392, 0.16905600], [0.16905600, 0.37282392], [0.07491100, 0.63149399],
    [0, 0.86840701], [0, 1.08849323], [0, CONTINUOUS_RUN],
];

/** The circular corner in the same ten points: a quarter circle as the middle curve, the others standing still. */
const ARC = 0.55228475;
const CIRCULAR = [
    [1, 0],
    [1, 0], [1, 0], [1, 0],
    [1 - ARC, 0], [0, 1 - ARC], [0, 1],
    [0, 1], [0, 1], [0, 1],
];

/**
 * The system font's ascent and line, in ems: Adwaita Sans's (hhea 1984 and
 * −494 of 2048) until the text backend says what the desktop's font is.
 * SwiftUI's is SF's, 0.952 and 1.193; the chip and the glyphs are centred in
 * their rows, so the line they stand on is the font's own.
 */
const system = {ascent: 0.96875, lineHeight: 1.2100};

/** What the system font the text backend resolved stands on, in ems (`{ascent, lineHeight}`). */
export function setSystemFontMetrics(metrics) {
    system.ascent = metrics.ascent;
    system.lineHeight = metrics.lineHeight;
}

/** Where the font stands on the line: Geist's own, and the system font's. */
export function lineMetrics(font) {
    if (font.family === 'system')
        return {ascent: font.size * system.ascent, height: font.size * system.lineHeight};
    return {ascent: font.size * GEIST.ascent, height: font.size * GEIST.lineHeight};
}

export class Gfx {
    /**
     * @param cr a Cairo-style context (see cairo-canvas.js)
     * @param text a backend: `draw(cr, str, x, y, font, rgba, align, maxWidth)` and `measure(str, font)`
     */
    constructor(cr, text) {
        this.cr = cr;
        this.text = text;
        this.alpha = 1;
        this._alphas = [];
        /** How many pictures of their own (`group`, `flattened`) the drawing is inside now. */
        this._groups = 0;
    }

    /**
     * Whether what is drawn now goes straight onto the surface, at full strength:
     * no fade in force and no picture of its own to be laid down later. Only so
     * can a part of the drawing be handed to a layer over the surface and look the same.
     */
    get plain() {
        return this.alpha >= 0.999 && this._groups === 0;
    }

    /** Everything drawn inside `fn` is that much fainter, multiplied into what is already. */
    withAlpha(alpha, fn) {
        this._alphas.push(this.alpha);
        this.alpha *= alpha;
        try {
            fn();
        } finally {
            this.alpha = this._alphas.pop();
        }
    }

    /**
     * Everything drawn inside `fn` is drawn as one picture and laid down that
     * much fainter, as SwiftUI's `.opacity` fades a view: where two shapes
     * overlap inside, the overlap is no darker than either. Inside, the
     * drawing is at full strength; the fade (and any fade already in force)
     * is applied once, as the group is painted.
     */
    group(alpha, fn) {
        if (alpha >= 0.999) {
            fn();
            return;
        }
        const cr = this.cr;
        if (!cr.pushGroup) {
            this.withAlpha(alpha, fn);
            return;
        }
        const outer = this.alpha;
        cr.pushGroup();
        this._alphas.push(outer);
        this.alpha = 1;
        this._groups++;
        try {
            fn();
        } finally {
            this._groups--;
            this.alpha = this._alphas.pop();
            cr.popGroupToSource();
            cr.paintWithAlpha(Math.max(0, alpha) * outer);
        }
    }

    /**
     * Draws `fn` at full strength as one picture and lays it down at the fade
     * already in force: for drawing that sets its own colours (Kapa), which the
     * fade would not otherwise reach.
     */
    flattened(fn) {
        const alpha = this.alpha;
        if (alpha >= 0.999 || !this.cr.pushGroup) {
            fn();
            return;
        }
        this._alphas.push(alpha);
        this.alpha = 1;
        this.cr.pushGroup();
        this._groups++;
        try {
            fn();
        } finally {
            this._groups--;
            this.alpha = this._alphas.pop();
            this.cr.popGroupToSource();
            this.cr.paintWithAlpha(alpha);
        }
    }

    /**
     * Draws `fn` clipped to the rectangle, on a picture of its own that begins
     * where the rectangle does, and lays it down. A gradient's shading falls a
     * shade differently on a surface that begins somewhere else; drawn so, what
     * `fn` draws comes out the same to the last bit wherever its surface begins
     * (Kapa on the surface, or on a layer of her own).
     */
    isolated(x, y, w, h, fn) {
        const cr = this.cr;
        if (!cr.pushGroup) {
            fn();
            return;
        }
        cr.save();
        cr.newPath();
        cr.rectangle(x, y, w, h);
        cr.clip();
        cr.pushGroup();
        try {
            fn();
        } finally {
            cr.popGroupToSource();
            cr.paint();
            cr.restore();
        }
    }

    color(c, extra = 1) {
        this.cr.setSourceRGBA(c[0], c[1], c[2], (c[3] ?? 1) * extra * this.alpha);
    }

    save() { this.cr.save(); }
    restore() { this.cr.restore(); }
    translate(x, y) { this.cr.translate(x, y); }

    /** Draws inside `fn` clipped to the path `path` adds. */
    clipped(path, fn) {
        this.cr.save();
        this.cr.newPath();
        path(this.cr);
        this.cr.clip();
        try {
            fn();
        } finally {
            this.cr.restore();
        }
    }

    /**
     * A rounded rectangle's outline. Corners are SwiftUI's `.continuous` ones
     * unless `circular`: the curvature eases in along each side, so the
     * corner starts about 1.53 radii from the vertex rather than one (the
     * well-known cubic approximation of Apple's shape). Where a side is too
     * short for that run, the corner gives way towards a circular one, so a
     * radius of half the height is still a true capsule.
     */
    roundRectPath(x, y, w, h, r, {circular = false} = {}) {
        const cr = this.cr;
        const half = Math.max(Math.min(w, h) / 2, 0);
        r = clamp(r, 0, half);
        cr.newPath();
        if (r <= 0) {
            cr.rectangle(x, y, w, h);
            return;
        }
        // How much of the continuous run there is room for: 1 the whole of it, 0 none (a circular arc).
        const smooth = circular ? 0 : clamp((Math.min(CONTINUOUS_RUN * r, half) / r - 1) / (CONTINUOUS_RUN - 1), 0, 1);
        const corner = CONTINUOUS.map(([ca, cb], i) => {
            const [qa, qb] = CIRCULAR[i];
            return [(qa + (ca - qa) * smooth) * r, (qb + (cb - qb) * smooth) * r];
        });
        const ext = corner[0][0];
        // Each corner in its own frame: `a` back along the side arriving at it, `b` along the side leaving it.
        const corners = [
            (a, b) => [x + w - a, y + b],
            (a, b) => [x + w - b, y + h - a],
            (a, b) => [x + a, y + h - b],
            (a, b) => [x + b, y + a],
        ];
        cr.moveTo(x + ext, y);
        for (const at of corners) {
            const p = corner.map(([a, b]) => at(a, b));
            cr.lineTo(...p[0]);
            cr.curveTo(...p[1], ...p[2], ...p[3]);
            cr.curveTo(...p[4], ...p[5], ...p[6]);
            cr.curveTo(...p[7], ...p[8], ...p[9]);
        }
        cr.closePath();
    }

    fillRect(x, y, w, h, c) {
        this.color(c);
        this.cr.newPath();
        this.cr.rectangle(x, y, w, h);
        this.cr.fill();
    }

    fillRoundRect(x, y, w, h, r, c, {circular = false} = {}) {
        this.color(c);
        this.roundRectPath(x, y, w, h, r, {circular});
        this.cr.fill();
    }

    strokeRoundRect(x, y, w, h, r, c, lineWidth = 1, {circular = false} = {}) {
        this.color(c);
        this.cr.setLineWidth(lineWidth);
        this.roundRectPath(x, y, w, h, r, {circular});
        this.cr.stroke();
    }

    /** An image a host loaded (`scene.images`), stretched into the box, a little fainter if `alpha`. */
    drawImage(image, x, y, w, h) {
        if (!image)
            return;
        this.cr.save();
        this.cr.drawImage(image, x, y, w, h, this.alpha);
        this.cr.restore();
    }

    /** A dashed outline inside the box, as SwiftUI's `strokeBorder` draws one. */
    dashedRoundRect(x, y, w, h, r, c, lineWidth, dash, {circular = false} = {}) {
        const half = lineWidth / 2;
        this.color(c);
        this.cr.setLineWidth(lineWidth);
        this.cr.setDash(dash, 0);
        this.roundRectPath(x + half, y + half, w - lineWidth, h - lineWidth, Math.max(r - half, 0), {circular});
        this.cr.stroke();
        this.cr.setDash([], 0);
    }

    fillCircle(cx, cy, r, c) {
        this.color(c);
        this.cr.newPath();
        this.cr.moveTo(cx + r, cy);
        this.cr.arc(cx, cy, r, 0, 2 * Math.PI);
        this.cr.closePath();
        this.cr.fill();
    }

    strokeCircle(cx, cy, r, c, lineWidth = 1) {
        this.color(c);
        this.cr.setLineWidth(lineWidth);
        this.cr.newPath();
        this.cr.moveTo(cx + r, cy);
        this.cr.arc(cx, cy, r, 0, 2 * Math.PI);
        this.cr.closePath();
        this.cr.stroke();
    }

    /** An open arc stroke, `from` and `to` in radians as Cairo takes them. */
    strokeArc(cx, cy, r, from, to, c, lineWidth, round = true) {
        this.color(c);
        this.cr.setLineWidth(lineWidth);
        this.cr.setLineCap(round ? 1 : 0);
        this.cr.newPath();
        this.cr.arc(cx, cy, r, from, to);
        this.cr.stroke();
    }

    /**
     * Draws a line of text with the top of its line box at `y`; `align`
     * says what `x` is (left edge, centre or right edge). With `maxWidth`
     * a longer line ends in an ellipsis. Returns the width drawn.
     */
    drawText(str, x, y, font, c, {align = 'left', maxWidth = null} = {}) {
        if (str === '' || str == null)
            return 0;
        const rgba = [c[0], c[1], c[2], (c[3] ?? 1) * this.alpha];
        return this.text.draw(this.cr, String(str), x, y, font, rgba, align, maxWidth);
    }

    measureText(str, font) {
        return this.text.measure(String(str), font);
    }

    lineHeight(font) {
        return lineMetrics(font).height;
    }
}

/** A text backend for tests: every glyph is half an em wide, and what is drawn is recorded. */
export class RecordingText {
    constructor() {
        this.calls = [];
    }

    measure(str, font) {
        return str.length * font.size * 0.5;
    }

    draw(_cr, str, x, y, font, rgba, align, maxWidth) {
        const width = this.measure(str, font);
        this.calls.push({str, x, y, font, rgba, align, maxWidth, width});
        return width;
    }
}
