// The Cairo drawing calls the shared modules use, on a Canvas 2D context, so
// the web surface draws with the very code the GNOME one does.

export class CairoCanvas {
    constructor(ctx) {
        this.ctx = ctx;
        this._rule = 'nonzero';
        ctx.beginPath();
    }

    setSourceRGBA(r, g, b, a = 1) {
        const color = `rgba(${Math.round(r * 255)},${Math.round(g * 255)},${Math.round(b * 255)},${a})`;
        this.ctx.fillStyle = color;
        this.ctx.strokeStyle = color;
        this._source = null;
    }

    setLineWidth(width) { this.ctx.lineWidth = width; }
    setLineCap(cap) { this.ctx.lineCap = cap === 1 ? 'round' : cap === 2 ? 'square' : 'butt'; }
    setFillRule(rule) { this._rule = rule === 1 ? 'evenodd' : 'nonzero'; }

    moveTo(x, y) { this.ctx.moveTo(x, y); }
    lineTo(x, y) { this.ctx.lineTo(x, y); }
    curveTo(x1, y1, x2, y2, x, y) { this.ctx.bezierCurveTo(x1, y1, x2, y2, x, y); }
    closePath() { this.ctx.closePath(); }
    rectangle(x, y, w, h) { this.ctx.rect(x, y, w, h); }
    arc(cx, cy, r, a0, a1) { this.ctx.arc(cx, cy, r, a0, a1); }

    fill() {
        this.ctx.fill(this._rule);
        this._rule = 'nonzero';
        this.ctx.beginPath();
    }

    stroke() {
        this.ctx.stroke();
        this.ctx.beginPath();
    }

    // MARK: the scene's additions — each is the Cairo call of the same name.
    save() { this.ctx.save(); }
    restore() { this.ctx.restore(); this._rule = 'nonzero'; }
    translate(x, y) { this.ctx.translate(x, y); }
    newPath() { this.ctx.beginPath(); }
    clip() { this.ctx.clip(); this.ctx.beginPath(); }

    // MARK: Kapa's additions (linux/js/ui/kapa). Each names the Cairo call it
    // stands for; the GNOME side reaches the same names through
    // `ui/kapa/cairo-gjs.js`.

    /** `cr.scale(sx, sy)` */
    scale(sx, sy) { this.ctx.scale(sx, sy); }

    /** `cr.rotate(radians)` */
    rotate(radians) { this.ctx.rotate(radians); }

    /** `cr.setLineJoin(join)` — 0 miter, 1 round, 2 bevel, as Cairo numbers them. */
    setLineJoin(join) { this.ctx.lineJoin = join === 1 ? 'round' : join === 2 ? 'bevel' : 'miter'; }

    /** `cr.setDash(dashes, offset)`; an empty list is a solid line. */
    setDash(dashes, offset = 0) {
        this.ctx.setLineDash(dashes);
        this.ctx.lineDashOffset = offset;
    }

    /**
     * A linear gradient as the source, from (x0, y0) to (x1, y1), in user space
     * as it stands now. `stops` is `[[offset, r, g, b, a], ...]`.
     *
     * GJS: `const g = new Cairo.LinearGradient(x0, y0, x1, y1);`
     *      `for (const [o, r, gg, b, a] of stops) g.addColorStopRGBA(o, r, gg, b, a);`
     *      `cr.setSource(g);`
     */
    setSourceLinear(x0, y0, x1, y1, stops) {
        this._gradient(this.ctx.createLinearGradient(x0, y0, x1, y1), stops);
    }

    /**
     * A radial gradient as the source, from the circle (cx0, cy0, r0) to the
     * circle (cx1, cy1, r1).
     *
     * GJS: `new Cairo.RadialGradient(cx0, cy0, r0, cx1, cy1, r1)`, then as above.
     */
    setSourceRadial(cx0, cy0, r0, cx1, cy1, r1, stops) {
        this._gradient(this.ctx.createRadialGradient(cx0, cy0, r0, cx1, cy1, r1), stops);
    }

    _gradient(gradient, stops) {
        for (const [offset, r, g, b, a = 1] of stops)
            gradient.addColorStop(offset, `rgba(${Math.round(r * 255)},${Math.round(g * 255)},${Math.round(b * 255)},${a})`);
        this.ctx.fillStyle = gradient;
        this.ctx.strokeStyle = gradient;
        this._source = null;
    }

    /**
     * `cr.pushGroup()`: what follows is drawn on a canvas of its own, the same
     * size, with the same transform, until `popGroupToSource()` or `popGroup()`.
     * The canvases are kept, one for each depth of nesting.
     */
    pushGroup() {
        this._groups ??= [];
        this._spare ??= [];
        const outer = this.ctx;
        const width = outer.canvas?.width ?? 1, height = outer.canvas?.height ?? 1;
        let canvas = this._spare[this._groups.length];
        if (!canvas || canvas.width !== width || canvas.height !== height) {
            canvas = typeof OffscreenCanvas !== 'undefined'
                ? new OffscreenCanvas(width, height)
                : globalThis.document?.createElement('canvas');
            if (!canvas) {
                // Nowhere to draw a group (no DOM): what follows is drawn straight through, unfaded.
                this._groups.push({outer, canvas: null, rule: this._rule});
                return;
            }
            canvas.width = width;
            canvas.height = height;
            this._spare[this._groups.length] = canvas;
        }
        const ctx = canvas.getContext('2d');
        ctx.setTransform(1, 0, 0, 1, 0, 0);
        ctx.globalAlpha = 1;
        ctx.globalCompositeOperation = 'source-over';
        ctx.clearRect(0, 0, width, height);
        if (outer.getTransform)
            ctx.setTransform(outer.getTransform());
        ctx.beginPath();
        this._groups.push({outer, canvas, rule: this._rule});
        this.ctx = ctx;
    }

    /**
     * `cr.popGroup()`: ends the group and returns it as a pattern (its canvas),
     * fixed to the user space as it stands now, for `setSource`.
     */
    popGroup() {
        const group = this._groups?.pop();
        if (!group)
            return null;
        this.ctx = group.outer;
        this._rule = group.rule;
        if (group.canvas) {
            this._placed ??= new WeakMap();
            this._placed.set(group.canvas, this._translation());
        }
        return group.canvas;
    }

    /** `cr.popGroupToSource()` */
    popGroupToSource() {
        this.setSource(this.popGroup());
    }

    /** `cr.setSource(pattern)`: a pattern `popGroup` returned. A colour set after it replaces it. */
    setSource(pattern) {
        this._source = pattern ?? null;
    }

    /** `cr.setOperator(op)`, in Cairo's numbers: 2 OVER, 5 ATOP, 12 ADD; others draw over. */
    setOperator(op) {
        this.ctx.globalCompositeOperation = op === 5 ? 'source-atop' : op === 12 ? 'lighter' : 'source-over';
    }

    /** `cr.paint()`: the source everywhere, under the clip. */
    paint() {
        this.paintWithAlpha(1);
    }

    /** `cr.paintWithAlpha(alpha)`: the source everywhere, that faint. */
    paintWithAlpha(alpha) {
        const ctx = this.ctx;
        const source = this._source;
        if (!source && this._groups?.some(g => !g.canvas))
            return; // drawn straight through: a paint would cover what is under the group
        ctx.save();
        ctx.globalAlpha = ctx.globalAlpha * alpha;
        if (source) {
            // Where the pattern was fixed, moved as the user space has moved since.
            const at = this._placed?.get(source) ?? {x: 0, y: 0};
            const now = this._translation();
            ctx.setTransform(1, 0, 0, 1, 0, 0);
            ctx.drawImage(source, now.x - at.x, now.y - at.y);
        } else {
            const width = ctx.canvas?.width ?? 0, height = ctx.canvas?.height ?? 0;
            ctx.setTransform(1, 0, 0, 1, 0, 0);
            ctx.fillRect(0, 0, width, height);
        }
        ctx.restore();
    }

    /**
     * A linear gradient as a pattern, for `mask`: its numbers, made into a
     * gradient on the canvas it masks. GJS: `CairoGjs.linearGradient`.
     */
    linearGradient(x0, y0, x1, y1, stops) {
        return {points: [x0, y0, x1, y1], stops};
    }

    /**
     * `cr.mask(pattern)`: the source painted through the pattern's alpha — the
     * source drawn on a canvas of its own, cut by the gradient
     * (`destination-in`), and laid down under the clip.
     */
    mask(pattern) {
        const ctx = this.ctx;
        const source = this._source;
        if (!source && this._groups?.some(g => !g.canvas))
            return; // drawn straight through, as `paintWithAlpha`
        const width = ctx.canvas?.width ?? 1, height = ctx.canvas?.height ?? 1;
        let canvas = this._maskCanvas;
        if (!canvas || canvas.width !== width || canvas.height !== height) {
            canvas = typeof OffscreenCanvas !== 'undefined'
                ? new OffscreenCanvas(width, height)
                : globalThis.document?.createElement('canvas');
            if (!canvas) {
                this.paint(); // nowhere to cut it: unmasked
                return;
            }
            canvas.width = width;
            canvas.height = height;
            this._maskCanvas = canvas;
        }
        const m = canvas.getContext('2d');
        m.setTransform(1, 0, 0, 1, 0, 0);
        m.globalAlpha = 1;
        m.globalCompositeOperation = 'source-over';
        m.clearRect(0, 0, width, height);
        if (source) {
            const at = this._placed?.get(source) ?? {x: 0, y: 0};
            const now = this._translation();
            m.drawImage(source, now.x - at.x, now.y - at.y);
        } else {
            m.fillStyle = ctx.fillStyle;
            m.fillRect(0, 0, width, height);
        }
        // The gradient in the user space as it stands, as Cairo reads a pattern.
        if (ctx.getTransform)
            m.setTransform(ctx.getTransform());
        const gradient = m.createLinearGradient(...pattern.points);
        for (const [offset, r, g, b, a = 1] of pattern.stops)
            gradient.addColorStop(offset, `rgba(${Math.round(r * 255)},${Math.round(g * 255)},${Math.round(b * 255)},${a})`);
        m.globalCompositeOperation = 'destination-in';
        m.fillStyle = gradient;
        m.fillRect(-1e5, -1e5, 2e5, 2e5);
        ctx.save();
        ctx.setTransform(1, 0, 0, 1, 0, 0);
        ctx.drawImage(canvas, 0, 0);
        ctx.restore();
    }

    /** Where the user space's origin is in device pixels. */
    _translation() {
        const m = this.ctx.getTransform?.();
        return m ? {x: m.e, y: m.f} : {x: 0, y: 0};
    }

    /** Draws a loaded image (an `HTMLImageElement`/`ImageBitmap`) into the box. In GJS: `CairoGjs.drawImage` with a `Cairo.ImageSurface`. */
    drawImage(image, x, y, w, h, alpha = 1) {
        const before = this.ctx.globalAlpha;
        this.ctx.globalAlpha = before * alpha;
        this.ctx.drawImage(image, x, y, w, h);
        this.ctx.globalAlpha = before;
    }
}
