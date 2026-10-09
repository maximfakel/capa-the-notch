// Settings' icons, drawn as the Paper mockup draws them: outlines on a
// 16-point grid, round caps, 1.3 points wide (`SettingsIcon`). They are the
// page switcher's buttons too. y runs down.

const GRIDS = {refresh: [14, 14], chevrons: [10, 12]};
const LINE = {chevrons: 1.2, music: 1.4, teleprompter: 1.4, dictation: 1.4, permissions: 1.4, shelf: 1.4};

/** A little path builder that remembers the current point, so quad curves can be cubics. */
class P {
    constructor(cr, scale, ox, oy) {
        this.cr = cr;
        this.s = scale;
        this.ox = ox;
        this.oy = oy;
        this.x = 0;
        this.y = 0;
    }

    px(v) { return this.ox + v * this.s; }
    py(v) { return this.oy + v * this.s; }
    move(x, y) { this.x = x; this.y = y; this.cr.moveTo(this.px(x), this.py(y)); }
    line(x, y) { this.x = x; this.y = y; this.cr.lineTo(this.px(x), this.py(y)); }
    quad(x, y, cx, cy) {
        const x0 = this.x, y0 = this.y;
        this.cr.curveTo(
            this.px(x0 + (2 / 3) * (cx - x0)), this.py(y0 + (2 / 3) * (cy - y0)),
            this.px(x + (2 / 3) * (cx - x)), this.py(y + (2 / 3) * (cy - y)),
            this.px(x), this.py(y));
        this.x = x;
        this.y = y;
    }
    /** `from` and `to` in degrees as SwiftUI gives them, `clockwise: false`: visually clockwise on screen, y down. */
    arc(cx, cy, r, from, to) {
        const a0 = (from * Math.PI) / 180;
        let a1 = (to * Math.PI) / 180;
        while (a1 <= a0) a1 += 2 * Math.PI;
        this.cr.arc(this.px(cx), this.py(cy), r * this.s, a0, a1);
        this.x = cx + r * Math.cos(a1);
        this.y = cy + r * Math.sin(a1);
    }
    ellipse(x, y, w, h) {
        const cx = x + w / 2, cy = y + h / 2;
        this.cr.moveTo(this.px(x + w), this.py(cy));
        this.cr.arc(this.px(cx), this.py(cy), (w / 2) * this.s, 0, 2 * Math.PI);
        this.cr.closePath();
    }
    roundRect(x, y, w, h, r) {
        const {cr} = this;
        const X = v => this.px(v), Y = v => this.py(v), R = r * this.s;
        cr.moveTo(X(x) + R, Y(y));
        cr.lineTo(X(x + w) - R, Y(y));
        cr.arc(X(x + w) - R, Y(y) + R, R, -Math.PI / 2, 0);
        cr.lineTo(X(x + w), Y(y + h) - R);
        cr.arc(X(x + w) - R, Y(y + h) - R, R, 0, Math.PI / 2);
        cr.lineTo(X(x) + R, Y(y + h));
        cr.arc(X(x) + R, Y(y + h) - R, R, Math.PI / 2, Math.PI);
        cr.lineTo(X(x), Y(y) + R);
        cr.arc(X(x) + R, Y(y) + R, R, Math.PI, 1.5 * Math.PI);
        cr.closePath();
    }
    close() { this.cr.closePath(); }
}

export function iconGrid(name) {
    return GRIDS[name] ?? [16, 16];
}

function outline(p, name) {
    switch (name) {
    case 'general':
        p.ellipse(8 - 2.25, 8 - 2.25, 4.5, 4.5);
        for (const [a, b] of [
            [[8, 1.75], [8, 3.25]], [[8, 12.75], [8, 14.25]], [[14.25, 8], [12.75, 8]], [[3.25, 8], [1.75, 8]],
            [[12.42, 3.58], [11.36, 4.64]], [[4.64, 11.36], [3.58, 12.42]],
            [[12.42, 12.42], [11.36, 11.36]], [[4.64, 4.64], [3.58, 3.58]],
        ]) {
            p.move(...a);
            p.line(...b);
        }
        break;
    case 'providers':
        // The dial's upper half, then the needle.
        p.move(2.5, 11.5);
        p.arc(8, 11.5, 5.5, 180, 360);
        p.move(8, 11.5);
        p.line(10.5, 8);
        break;
    case 'alerts':
        p.move(4, 11);
        p.line(4, 7.5);
        p.arc(8, 7.5, 4, 180, 360);
        p.line(12, 11);
        p.line(13, 12.25);
        p.line(3, 12.25);
        p.close();
        p.move(6.75, 14);
        p.line(9.25, 14);
        break;
    case 'modules':
        for (const [x, y] of [[2, 2], [9, 2], [2, 9], [9, 9]])
            p.roundRect(x, y, 5, 5, 1.5);
        break;
    case 'diagnostics':
        p.move(1.75, 8);
        for (const [x, y] of [[4.25, 8], [5.75, 4], [8.25, 12], [9.75, 8], [14.25, 8]])
            p.line(x, y);
        break;
    case 'music':
        p.move(6, 12);
        p.line(6, 3.5);
        p.line(13, 2);
        p.line(13, 10.5);
        p.ellipse(4.5 - 1.75, 12 - 1.75, 3.5, 3.5);
        p.ellipse(11.5 - 1.75, 10.5 - 1.75, 3.5, 3.5);
        break;
    case 'teleprompter':
        // Three lines of a Script, the last one short.
        for (const [y, end] of [[4.5, 13], [8, 13], [11.5, 9]]) {
            p.move(3, y);
            p.line(end, y);
        }
        break;
    case 'dictation':
        p.roundRect(5.75, 1.75, 4.5, 7.5, 2.25);
        p.move(3.5, 7.25);
        p.quad(12.5, 7.25, 8, 16.25);
        p.move(8, 11.75);
        p.line(8, 14.25);
        break;
    case 'shelf':
        // The tray's rim, its dip, and its sides going up and in.
        p.move(1.75, 9.25);
        p.line(5.25, 9.25);
        p.line(6.25, 11);
        p.line(9.75, 11);
        p.line(10.75, 9.25);
        p.line(14.25, 9.25);
        p.move(1.75, 9.25);
        p.line(1.75, 12.25);
        p.quad(3.5, 14, 1.75, 14);
        p.line(12.5, 14);
        p.quad(14.25, 12.25, 14.25, 14);
        p.line(14.25, 9.25);
        p.move(1.75, 9.25);
        p.line(3.5, 3.9);
        p.quad(4.9, 3, 3.8, 3);
        p.line(11.1, 3);
        p.quad(12.5, 3.9, 12.2, 3);
        p.line(14.25, 9.25);
        break;
    case 'notch':
        p.move(6, 2.75);
        p.line(3.25, 2.75);
        p.quad(1.75, 4.25, 1.75, 2.75);
        p.line(1.75, 11.75);
        p.quad(3.25, 13.25, 1.75, 13.25);
        p.line(12.75, 13.25);
        p.quad(14.25, 11.75, 14.25, 13.25);
        p.line(14.25, 4.25);
        p.quad(12.75, 2.75, 14.25, 2.75);
        p.line(10, 2.75);
        p.line(10, 3.75);
        p.quad(9, 4.75, 10, 4.75);
        p.line(7, 4.75);
        p.quad(6, 3.75, 6, 4.75);
        p.close();
        break;
    case 'permissions':
        p.roundRect(3, 7, 10, 7.25, 1.75);
        p.move(5.25, 7);
        p.line(5.25, 4.75);
        p.arc(8, 4.75, 2.75, 180, 360);
        p.line(10.75, 7);
        p.move(8, 10);
        p.line(8, 11.25);
        break;
    case 'accessibility':
        p.ellipse(1.75, 1.75, 12.5, 12.5);
        p.ellipse(7.1, 3.85, 1.8, 1.8);
        p.move(4.75, 6.75);
        p.line(11.25, 6.75);
        p.move(8, 6.75);
        p.line(8, 9.25);
        p.line(6.25, 12);
        p.move(8, 9.25);
        p.line(9.75, 12);
        break;
    case 'automation':
        p.roundRect(1.75, 3.75, 12.5, 8.5, 1.75);
        for (const x of [4.5, 6.75, 9.25, 11.5]) {
            p.move(x, 6.5);
            p.line(x + 0.01, 6.5);
        }
        p.move(5.5, 9.5);
        p.line(10.5, 9.5);
        break;
    case 'refresh':
        // Most of a circle from three o'clock round to half past one, and its arrowhead.
        p.move(11.5, 7);
        p.arc(7, 7, 4.5, 0, 315);
        p.move(10.5, 1.75);
        p.line(10.5, 4.25);
        p.line(8, 4.25);
        break;
    case 'close':
        p.move(3.5, 3.5);
        p.line(12.5, 12.5);
        p.move(12.5, 3.5);
        p.line(3.5, 12.5);
        break;
    case 'copy':
        p.roundRect(5.5, 5.5, 8, 8, 1.75);
        p.move(10.5, 3.5);
        p.line(4.5, 3.5);
        p.quad(2.75, 5.25, 2.75, 3.5);
        p.line(2.75, 10.5);
        break;
    case 'trash':
        p.move(2.5, 4.25);
        p.line(13.5, 4.25);
        p.move(6.25, 4.25);
        p.line(6.25, 2.75);
        p.line(9.75, 2.75);
        p.line(9.75, 4.25);
        p.move(4, 4.25);
        p.line(4.6, 13);
        p.quad(5.75, 13.75, 4.7, 13.75);
        p.line(10.25, 13.75);
        p.quad(11.4, 13, 11.3, 13.75);
        p.line(12, 4.25);
        break;
    case 'chevrons':
        p.move(2.5, 4.25);
        p.line(5, 1.75);
        p.line(7.5, 4.25);
        p.move(2.5, 7.75);
        p.line(5, 10.25);
        p.line(7.5, 7.75);
        break;
    default:
        break;
    }
}

/**
 * One icon, centred on (cx, cy), scaled by `scale` about its centre (the
 * switcher's buttons draw them at 0.75), in `color`.
 */
export function drawIcon(g, name, cx, cy, scale, color) {
    const [gw, gh] = iconGrid(name);
    const p = new P(g.cr, scale, cx - (gw * scale) / 2, cy - (gh * scale) / 2);
    g.color(color);
    g.cr.setLineWidth((LINE[name] ?? 1.3) * scale);
    g.cr.setLineCap(1);
    g.cr.setLineJoin(1);
    g.cr.newPath();
    outline(p, name);
    g.cr.stroke();
    if (name === 'providers') {
        // Filled: the dial's hub.
        g.cr.newPath();
        g.cr.moveTo(p.px(9), p.py(11.5));
        g.cr.arc(p.px(8), p.py(11.5), 1 * scale, 0, 2 * Math.PI);
        g.cr.closePath();
        g.cr.fill();
    }
}
