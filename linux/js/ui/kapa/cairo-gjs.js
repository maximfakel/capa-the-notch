// The GNOME side of the Cairo-style context the shared drawing is written
// against. GJS's `Cairo.Context` already has most of the calls under the same
// names (camelCase); this wraps one so the rest — gradients, the dash, the
// arguments the shared modules pass — mean the same thing on both sides.
//
//     import Cairo from 'gi://cairo';
//     area.connect('repaint', () => {
//         const cr = new CairoGjs(area.get_context(), Cairo);
//         try { engine.draw(cr, {size}); } finally { cr.dispose(); }
//     });
//
// The numbers Cairo uses for cap, join and fill rule are the numbers the
// shared modules pass (0 butt / 1 round / 2 square; 0 miter / 1 round /
// 2 bevel; 0 winding / 1 even-odd), so they go through unchanged.

const CACHE = new Map();
const CACHE_LIMIT = 512;

function remember(key, gradient) {
    if (CACHE.size >= CACHE_LIMIT)
        CACHE.clear();
    CACHE.set(key, gradient);
}

export class CairoGjs {
    /** @param {object} cr a `Cairo.Context` @param {object} Cairo the `gi://cairo` module */
    constructor(cr, Cairo) {
        this.cr = cr;
        this.Cairo = Cairo;
    }

    dispose() { this.cr.$dispose(); }

    setSourceRGBA(r, g, b, a = 1) { this.cr.setSourceRGBA(r, g, b, a); }
    setLineWidth(width) { this.cr.setLineWidth(width); }
    setLineCap(cap) { this.cr.setLineCap(cap); }
    setLineJoin(join) { this.cr.setLineJoin(join); }
    setFillRule(rule) { this.cr.setFillRule(rule); }
    setDash(dashes, offset = 0) { this.cr.setDash(dashes, offset); }

    moveTo(x, y) { this.cr.moveTo(x, y); }
    lineTo(x, y) { this.cr.lineTo(x, y); }
    curveTo(x1, y1, x2, y2, x, y) { this.cr.curveTo(x1, y1, x2, y2, x, y); }
    closePath() { this.cr.closePath(); }
    rectangle(x, y, w, h) { this.cr.rectangle(x, y, w, h); }
    arc(cx, cy, r, a0, a1) { this.cr.arc(cx, cy, r, a0, a1); }
    newPath() { this.cr.newPath(); }

    fill() { this.cr.fill(); }
    stroke() { this.cr.stroke(); }
    clip() { this.cr.clip(); }

    save() { this.cr.save(); }
    restore() { this.cr.restore(); }

    // A group: what is drawn between `pushGroup` and `popGroupToSource` goes
    // to a picture of its own, which then becomes the source to paint.
    pushGroup() { this.cr.pushGroup(); }
    popGroupToSource() { this.cr.popGroupToSource(); }
    paintWithAlpha(alpha) { this.cr.paintWithAlpha(alpha); }
    /** The group as a pattern, to be set as a source later (`setSource`). */
    popGroup() { return this.cr.popGroup(); }
    setSource(pattern) { this.cr.setSource(pattern); }
    paint() { this.cr.paint(); }
    /** Cairo's own numbers: 2 OVER, 5 ATOP. */
    setOperator(op) { this.cr.setOperator(op); }
    translate(x, y) { this.cr.translate(x, y); }
    scale(sx, sy) { this.cr.scale(sx, sy); }
    rotate(radians) { this.cr.rotate(radians); }

    // A gradient is made once for each distinct set of numbers and kept. Made
    // afresh every frame, as it once was, each is a native object the garbage
    // collector is slow to see the weight of — inside the Shell, that is how
    // memory climbs. The pattern takes the matrix in force when it is set, so
    // one object serves wherever Kapa is drawn.
    setSourceLinear(x0, y0, x1, y1, stops) {
        this.cr.setSource(this.linearGradient(x0, y0, x1, y1, stops));
    }

    /** A linear gradient as a pattern, for `mask`; kept as a source gradient is. */
    linearGradient(x0, y0, x1, y1, stops) {
        const key = `L${x0},${y0},${x1},${y1}|${stops.join(';')}`;
        let gradient = CACHE.get(key);
        if (!gradient) {
            gradient = new this.Cairo.LinearGradient(x0, y0, x1, y1);
            this._stops(gradient, stops);
            remember(key, gradient);
        }
        return gradient;
    }

    /** `cr.mask(pattern)`: the source painted through the pattern's alpha. */
    mask(pattern) { this.cr.mask(pattern); }

    setSourceRadial(cx0, cy0, r0, cx1, cy1, r1, stops) {
        const key = `R${cx0},${cy0},${r0},${cx1},${cy1},${r1}|${stops.join(';')}`;
        let gradient = CACHE.get(key);
        if (!gradient) {
            gradient = new this.Cairo.RadialGradient(cx0, cy0, r0, cx1, cy1, r1);
            this._stops(gradient, stops);
            remember(key, gradient);
        }
        this.cr.setSource(gradient);
    }

    _stops(gradient, stops) {
        for (const [offset, r, g, b, a = 1] of stops)
            gradient.addColorStopRGBA(offset, r, g, b, a);
    }

    /** Draws a `Cairo.ImageSurface` (from `Cairo.ImageSurface.createFromPNG`) stretched into the box. */
    drawImage(surface, x, y, w, h, alpha = 1) {
        const sw = surface.getWidth(), sh = surface.getHeight();
        if (!sw || !sh)
            return;
        this.cr.save();
        this.cr.translate(x, y);
        this.cr.scale(w / sw, h / sh);
        this.cr.setSourceSurface(surface, 0, 0);
        if (alpha < 1)
            this.cr.paintWithAlpha(alpha);
        else
            this.cr.paint();
        this.cr.restore();
    }
}
