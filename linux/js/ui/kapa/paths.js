// Every shape in the sheet's 100-unit square, y down, as drawn in Paper — a
// port of `KapaPaths` in Sources/CapacityNotch/KapaView.swift. All of it is
// written against the Cairo-style context (`linux/js/cairo-canvas.js`);
// nothing here knows which toolkit is underneath.

import {KapaGaze} from './motion.js';

/** One of the sheet's colours, as Paper writes it, as `[r, g, b]` in 0...1. */
export const hex = value => [((value >> 16) & 0xFF) / 255, ((value >> 8) & 0xFF) / 255, (value & 0xFF) / 255];

export const INK = hex(0x102C35);
const AMBER = hex(0xF2B35D);
const NOTE = hex(0x51D4DE);
const WHITE = [1, 1, 1];

/** `colour` with `alpha` applied; Swift's `.opacity` on a solid colour. */
const withAlpha = (colour, alpha) => [colour[0], colour[1], colour[2], alpha * (colour[3] ?? 1)];

const CIRCLE = 0.5522847498307936;
/** Where a circular quarter's control points sit, in radii from the corner. */
const CIRCLE_REST = 1 - CIRCLE;

// MARK: - Path helpers

/** A quadratic curve from (x0, y0), as the cubic Cairo has (it has no quadratic). */
function quad(cr, x0, y0, cx, cy, x1, y1) {
    cr.curveTo(x0 + (2 / 3) * (cx - x0), y0 + (2 / 3) * (cy - y0), x1 + (2 / 3) * (cx - x1), y1 + (2 / 3) * (cy - y1), x1, y1);
}

/** `Path(ellipseIn:)` — four cubic curves, so no transform is involved. */
export function ellipsePath(cr, cx, cy, rx, ry) {
    const kx = rx * CIRCLE;
    const ky = ry * CIRCLE;
    cr.moveTo(cx + rx, cy);
    cr.curveTo(cx + rx, cy + ky, cx + kx, cy + ry, cx, cy + ry);
    cr.curveTo(cx - kx, cy + ry, cx - rx, cy + ky, cx - rx, cy);
    cr.curveTo(cx - rx, cy - ky, cx - kx, cy - ry, cx, cy - ry);
    cr.curveTo(cx + kx, cy - ry, cx + rx, cy - ky, cx + rx, cy);
    cr.closePath();
}

/**
 * Apple's continuous corner, one quarter, in the corner's own frame: `a` along
 * the edge the corner is entered from, `b` along the one it leaves by, both in
 * corner radii from the rectangle's corner. The curve leaves the straight
 * 1.528 radii before the corner rather than 1, so the curvature eases in — the
 * iOS 7 squircle as it is commonly reverse-engineered. Each is
 * `[c1a, c1b, c2a, c2b, a, b]` for a curve, `[a, b]` for a line.
 */
const CONTINUOUS = [
    [1.08849299, 0, 0.86840701, 0, 0.66993397, 0.06549600],
    [0.63149399, 0.07491100],
    [0.37282401, 0.16906001, 0.16906001, 0.37282401, 0.07491100, 0.63149399],
    [0.06549600, 0.66993397],
    [0, 0.86840701, 0, 1.08849299, 0, 1.52866483],
];
/** The same steps for a circular corner, so the two can be blended. */
const CIRCULAR = [
    [1, 0, 1, 0, 1, 0],
    [1, 0],
    [CIRCLE_REST, 0, 0, CIRCLE_REST, 0, 1],
    [0, 1],
    [0, 1, 0, 1, 0, 1],
];
/** How far a continuous corner reaches along each edge, in radii. */
const CONTINUOUS_REACH = 1.52866483;

/**
 * `Path(roundedRect:cornerRadius:)` and `addRoundedRect(in:cornerSize:)`,
 * whose style is `.continuous` unless asked otherwise: Apple's smooth corner.
 * The radius is held to half the shorter side; where the full continuous
 * corner would not fit in what is left (an earcup, 12 wide with a radius of
 * 5) it is blended towards a circular one until it does, so a radius of half
 * the side is a capsule's round end, as SwiftUI draws it.
 */
export function roundedRectPath(cr, x, y, w, h, radius) {
    const half = Math.min(w, h) / 2;
    const r = Math.max(0, Math.min(radius, half));
    if (r === 0) {
        cr.rectangle(x, y, w, h);
        return;
    }
    // 1 the full continuous corner, 0 a circular one.
    const smooth = Math.min(1, Math.max(0, (half / r - 1) / (CONTINUOUS_REACH - 1)));
    const steps = CONTINUOUS.map((step, i) => step.map((v, j) => (CIRCULAR[i][j] + (v - CIRCULAR[i][j]) * smooth) * r));
    const reach = (1 + (CONTINUOUS_REACH - 1) * smooth) * r;
    // Each corner: the point it stands at, and the unit steps along the edge
    // coming in (reversed, pointing back along it) and the one going out.
    const corners = [
        [x + w, y, -1, 0, 0, 1], // top right: in along the top, out down the right
        [x + w, y + h, 0, -1, -1, 0], // bottom right
        [x, y + h, 1, 0, 0, -1], // bottom left
        [x, y, 0, 1, 1, 0], // top left
    ];
    cr.moveTo(x + reach, y);
    for (const [cx, cy, ax, ay, bx, by] of corners) {
        const at = (a, b) => [cx + ax * a + bx * b, cy + ay * a + by * b];
        cr.lineTo(...at(reach, 0));
        for (const step of steps) {
            if (step.length === 2) cr.lineTo(...at(step[0], step[1]));
            else cr.curveTo(...at(step[0], step[1]), ...at(step[2], step[3]), ...at(step[4], step[5]));
        }
    }
    cr.closePath();
}

function polygonPath(cr, points) {
    points.forEach(([x, y], i) => (i === 0 ? cr.moveTo(x, y) : cr.lineTo(x, y)));
    cr.closePath();
}

function polylinePath(cr, points) {
    points.forEach(([x, y], i) => (i === 0 ? cr.moveTo(x, y) : cr.lineTo(x, y)));
}

function segmentsPath(cr, segments) {
    for (const [x1, y1, x2, y2] of segments) {
        cr.moveTo(x1, y1);
        cr.lineTo(x2, y2);
    }
}

// MARK: - Stroking and filling

function fillWith(cr, colour) {
    cr.setSourceRGBA(...colour);
    cr.fill();
}

/** Strokes the path in hand: width, cap and join set every time, so nothing leaks from before. */
function strokeWith(cr, colour, width, {cap = 1, join = 1, dash = []} = {}) {
    cr.setSourceRGBA(...colour);
    cr.setLineWidth(width);
    cr.setLineCap(cap);
    cr.setLineJoin(join);
    cr.setDash(dash, 0);
    cr.stroke();
    cr.setDash([], 0);
}

// MARK: - The body

/** The bell: a flat base, the curled tip at the top right. */
export function bodyPath(cr) {
    cr.newPath();
    cr.moveTo(14, 90);
    cr.curveTo(5, 90, 3, 82, 8, 73);
    cr.curveTo(15, 58, 17, 39, 31, 27);
    cr.curveTo(39, 20, 47, 17, 55, 18);
    cr.curveTo(59, 13, 62, 9, 67, 8);
    cr.curveTo(72, 9, 72, 16, 70, 22);
    cr.curveTo(80, 31, 85, 46, 91, 66);
    cr.curveTo(94, 76, 96, 90, 86, 90);
    cr.closePath();
}

/** The highlight: an ellipse in (26, 34, 16, 8) tilted 35° about its own centre. */
export function shinePath(cr) {
    cr.newPath();
    cr.save();
    cr.translate(34, 38);
    cr.rotate((-35 * Math.PI) / 180);
    ellipsePath(cr, 0, 0, 8, 4);
    cr.restore();
}

export const BODY_GRADIENT = {
    center: [36, 30],
    endRadius: 85,
    stops: [
        [0, ...hex(0xBDF5F8), 1],
        [0.42, ...hex(0x5BDBE4), 1],
        [1, ...hex(0x2FAFBD), 1],
    ],
};

/** Fills the body with the sheet's radial gradient, in the space the context is in now. */
export function fillBody(cr) {
    bodyPath(cr);
    cr.setSourceRadial(36, 30, 0, 36, 30, 85, BODY_GRADIENT.stops);
    cr.fill();
}

export function strokeBody(cr, colour, width) {
    bodyPath(cr);
    strokeWith(cr, colour, width, {cap: 0, join: 0});
}

export function fillShine(cr) {
    shinePath(cr);
    fillWith(cr, [1, 1, 1, 0.22]);
}

export function fillShadow(cr) {
    cr.newPath();
    ellipsePath(cr, 50, 91, 38, 2.6);
    fillWith(cr, [0, 0, 0, 0.5]);
}

export function fillCheeks(cr) {
    const cheek = [...hex(0xFF8FA3), 0.35];
    cr.newPath();
    ellipsePath(cr, 33, 70, 4, 2.2);
    fillWith(cr, cheek);
    cr.newPath();
    ellipsePath(cr, 71, 70, 4, 2.2);
    fillWith(cr, cheek);
}

export function drawHeadphones(cr) {
    cr.newPath();
    cr.moveTo(17, 56);
    cr.curveTo(15, 22, 86, 18, 87, 56);
    strokeWith(cr, hex(0x2E3236), 5, {cap: 1, join: 0});
    cr.newPath();
    roundedRectPath(cr, 10, 48, 12, 20, 5);
    roundedRectPath(cr, 82, 48, 12, 20, 5);
    fillWith(cr, hex(0x3B4146));
}

// MARK: - Small things that float

/** The music note's stem, from the origin: a flag and a stem, as drawn. */
function noteStemPath(cr) {
    cr.newPath();
    polylinePath(cr, [[0, 0], [0, -11], [6, -12.5], [6, -8]]);
}

function heartPath(cr) {
    cr.newPath();
    cr.moveTo(0, 4);
    cr.curveTo(-7, -1, -3, -6, 0, -2);
    cr.curveTo(3, -6, 7, -1, 0, 4);
    cr.closePath();
}

function dropPath(cr) {
    cr.newPath();
    cr.moveTo(0, -4);
    quad(cr, 0, -4, 4, 1.5, 0, 3);
    quad(cr, 0, 3, -4, 1.5, 0, -4);
    cr.closePath();
}

/** A "z", drawn rather than typed, so it scales with the rest. */
function sleepZPath(cr) {
    cr.newPath();
    polygonPath(cr, [
        [-3, -3], [3, -3], [3, -1.8], [-1, 1.8], [3, 1.8], [3, 3],
        [-3, 3], [-3, 1.8], [1, -1.8], [-3, -1.8],
    ]);
}

export function sparklePath(cr, r) {
    cr.newPath();
    polygonPath(cr, [
        [0, -r], [r * 0.25, -r * 0.25], [r, 0], [r * 0.25, r * 0.25],
        [0, r], [-r * 0.25, r * 0.25], [-r, 0], [-r * 0.25, -r * 0.25],
    ]);
}

/**
 * One particle, at the origin of the context it is given: `kind` is note,
 * heart, sparkle, sweat or sleep. `alpha` is the layer opacity the Swift
 * drawing sets. Each particle is one flat colour, so for most folding the
 * opacity into the colour draws the same; the note is a stem stroked over its
 * head, and where the two overlap a folded alpha would show twice, so it is
 * drawn whole into a group and the group faded — where the context has groups.
 */
export function drawParticle(cr, kind, boost, alpha) {
    if (kind === 'note' && alpha < 1 && typeof cr.pushGroup === 'function') {
        cr.pushGroup();
        drawParticleShape(cr, kind, boost, 1);
        cr.popGroupToSource();
        cr.paintWithAlpha(alpha);
        return;
    }
    drawParticleShape(cr, kind, boost, alpha);
}

function drawParticleShape(cr, kind, boost, alpha) {
    switch (kind) {
    case 'note':
        noteStemPath(cr);
        strokeWith(cr, withAlpha(NOTE, alpha), 1.8 * boost, {cap: 1, join: 0});
        cr.newPath();
        ellipsePath(cr, -1.7, 0, 2.3, 2.3);
        fillWith(cr, withAlpha(NOTE, alpha));
        break;
    case 'heart':
        heartPath(cr);
        fillWith(cr, withAlpha(hex(0xFF5C7A), alpha));
        break;
    case 'sparkle':
        sparklePath(cr, 5);
        fillWith(cr, withAlpha(AMBER, alpha));
        break;
    case 'sweat':
        dropPath(cr);
        fillWith(cr, withAlpha(hex(0x9BE7F0), alpha));
        break;
    case 'sleep':
        sleepZPath(cr);
        fillWith(cr, withAlpha(hex(0xC9D1D4), alpha));
        break;
    default:
        throw new Error(`no such particle: ${kind}`);
    }
}

// MARK: - Eyes

/**
 * One eye: placed and narrowed by the gaze, shut by `lid` (1 open). Draws
 * nothing for an eye that has gone round the side of the head.
 */
export function drawEye(cr, eyes, side, look, lid, boost) {
    const gaze = KapaGaze.eye(side, look);
    if (gaze.isHidden) return;
    const raise = eyes === 'wide' ? -2 : (eyes === 'uneven' && side > 0 ? 1 : 0);
    // A mini Kapa is read by its eyes alone, so there they are a fifth larger.
    const enlarge = boost > 1 ? 1.2 : 1;

    cr.save();
    cr.translate(gaze.x, gaze.y + raise);
    cr.scale(gaze.scaleX * enlarge, gaze.scaleY * enlarge * Math.max(lid, 0.08));

    const oval = (rx, ry, dy = 0, dx = 0) => {
        cr.newPath();
        ellipsePath(cr, dx, dy, rx, ry);
        fillWith(cr, INK);
    };
    const light = (x, y, r) => {
        cr.newPath();
        ellipsePath(cr, x, y, r, r);
        fillWith(cr, WHITE);
    };
    const arc = (x0, y0, cx, cy, x1, y1) => {
        cr.newPath();
        cr.moveTo(x0, y0);
        quad(cr, x0, y0, cx, cy, x1, y1);
        strokeWith(cr, INK, 2.6 * boost, {cap: 1, join: 0});
    };

    switch (eyes) {
    case 'open':
        oval(5, 6.5);
        light(1.6, -2.6, 1.6);
        break;
    case 'wide':
        oval(5.6, 7.4);
        light(1, -3.8, 1.8);
        break;
    case 'happy':
        arc(-5.5, 1, 0, -5.5, 5.5, 1);
        break;
    case 'closed':
        arc(-5.5, 0, 0, 5, 5.5, 0);
        break;
    case 'lidded':
        // A half disc, flat across the top: the lid drawn over the eye.
        cr.newPath();
        cr.moveTo(-5, 0);
        cr.lineTo(5, 0);
        cr.arc(0, 0, 5, 0, Math.PI);
        cr.closePath();
        fillWith(cr, INK);
        cr.newPath();
        segmentsPath(cr, [[-5.5, -0.5, 5.5, -0.5]]);
        strokeWith(cr, hex(0x1E5560), 1.6 * boost, {cap: 1, join: 0});
        break;
    case 'narrowed':
        oval(5, 3.4, 1);
        light(1.8, 0, 1.2);
        break;
    case 'uneven':
        if (side < 0) {
            oval(5, 6.5);
            light(1.5, -2.4, 1.5);
        } else {
            oval(4.2, 5);
            light(1.2, -1.8, 1.2);
        }
        break;
    default:
        throw new Error(`no such eyes: ${eyes}`);
    }
    cr.restore();
}

// MARK: - Brows and mouths

export function drawBrows(cr, brows, boost) {
    switch (brows) {
    case 'none':
        return;
    case 'worried':
        cr.newPath();
        segmentsPath(cr, [[35, 52, 46, 49], [58, 49, 69, 52]]);
        break;
    case 'puzzled':
        cr.newPath();
        cr.moveTo(35, 50.5);
        quad(cr, 35, 50.5, 40.5, 45.5, 46.5, 48.5);
        cr.moveTo(58.5, 53.5);
        cr.lineTo(68, 53.5);
        break;
    default:
        throw new Error(`no such brows: ${brows}`);
    }
    strokeWith(cr, INK, 2 * boost, {cap: 1, join: 0});
}

/** The closed mouth for a pose; an open one is drawn by the engine from `open`. */
export function drawMouth(cr, mouth, boost) {
    const curve = (x0, y0, cx, cy, x1, y1) => {
        cr.newPath();
        cr.moveTo(x0, y0);
        quad(cr, x0, y0, cx, cy, x1, y1);
        strokeWith(cr, INK, 2 * boost, {cap: 1, join: 1});
    };
    switch (mouth) {
    case 'smile': curve(48, 70, 52, 73.5, 56, 70); break;
    case 'small': curve(49, 70, 52, 72, 55, 70); break;
    case 'line':
        cr.newPath();
        segmentsPath(cr, [[49, 71, 55, 71]]);
        strokeWith(cr, INK, 2 * boost, {cap: 1, join: 1});
        break;
    case 'open':
        cr.newPath();
        ellipsePath(cr, 52, 73, 4.6, 5.6);
        fillWith(cr, INK);
        break;
    case 'grin':
        cr.newPath();
        cr.moveTo(47, 68);
        quad(cr, 47, 68, 52, 76, 57, 68);
        cr.closePath();
        fillWith(cr, INK);
        break;
    case 'worried': curve(48, 72, 52, 69.5, 56, 72); break;
    case 'wobble':
        cr.newPath();
        cr.moveTo(47, 71);
        quad(cr, 47, 71, 49.5, 69, 52, 71);
        quad(cr, 52, 71, 54.5, 73, 57, 71);
        strokeWith(cr, INK, 2 * boost, {cap: 1, join: 1});
        break;
    default:
        throw new Error(`no such mouth: ${mouth}`);
    }
}

/** An open mouth, as wide as appetite or a gulp has it. */
export function drawOpenMouth(cr, open) {
    cr.newPath();
    ellipsePath(cr, 52, 72 + 1.5 * open, 3 + 4 * open, 2 + 7.5 * open);
    fillWith(cr, INK);
}

// MARK: - Signs

/**
 * The signs, top right of the square where the tip leaves room; the file top
 * left, where a dropped one comes from.
 */
export function drawBadge(cr, badge, boost) {
    const stroke = (colour, width, dash = []) => strokeWith(cr, colour, width * boost, {cap: 1, join: 1, dash});
    const disc = () => {
        cr.newPath();
        ellipsePath(cr, 86, 16, 8.5, 8.5);
    };
    switch (badge) {
    case 'none':
        return;
    case 'check':
        disc();
        fillWith(cr, hex(0x34C759));
        cr.newPath();
        polylinePath(cr, [[81.8, 16.2], [85, 19.4], [90.5, 13]]);
        stroke(WHITE, 2.1);
        break;
    case 'alert':
        disc();
        fillWith(cr, AMBER);
        cr.newPath();
        segmentsPath(cr, [[86, 11.5, 86, 17]]);
        stroke(hex(0x2A1B05), 2.2);
        cr.newPath();
        ellipsePath(cr, 86, 20.6, 1.3, 1.3);
        fillWith(cr, hex(0x2A1B05));
        break;
    case 'clock':
        disc();
        stroke(AMBER, 2.2);
        cr.newPath();
        polylinePath(cr, [[86, 11.5], [86, 16], [89.5, 18]]);
        stroke(AMBER, 2.2);
        break;
    case 'dashedClock':
        disc();
        stroke(hex(0x9AA3A8), 1.6, [2.6, 2.2]);
        cr.newPath();
        polylinePath(cr, [[86, 11.5], [86, 16], [89, 18]]);
        stroke(hex(0xC9D1D4), 1.6);
        break;
    case 'cross':
        disc();
        fillWith(cr, hex(0xFF453A));
        cr.newPath();
        segmentsPath(cr, [[82.8, 12.8, 89.2, 19.2], [89.2, 12.8, 82.8, 19.2]]);
        stroke(WHITE, 2);
        break;
    case 'clipboard':
        cr.newPath();
        roundedRectPath(cr, 78, 8, 17, 21, 3);
        fillWith(cr, hex(0x2A2E32));
        roundedRectPath(cr, 78, 8, 17, 21, 3);
        stroke(AMBER, 1.4);
        cr.newPath();
        roundedRectPath(cr, 82.5, 5.5, 8, 4.5, 1.5);
        fillWith(cr, AMBER);
        cr.newPath();
        segmentsPath(cr, [[81.5, 16, 91.5, 16], [81.5, 20, 91.5, 20], [81.5, 24, 87, 24]]);
        stroke(hex(0xC9D1D4), 1.2);
        break;
    case 'file':
        cr.newPath();
        polygonPath(cr, [[8, 2], [19, 2], [24, 7], [24, 22], [8, 22]]);
        fillWith(cr, hex(0xF2F4F5));
        cr.newPath();
        polygonPath(cr, [[19, 2], [19, 7], [24, 7]]);
        fillWith(cr, hex(0xC9CFD2));
        cr.newPath();
        segmentsPath(cr, [[11, 11, 21, 11], [11, 14.5, 21, 14.5], [11, 18, 17, 18]]);
        stroke(hex(0x9AA3A8), 1.2);
        break;
    case 'note':
        cr.save();
        cr.translate(93, 17);
        noteStemPath(cr);
        strokeWith(cr, NOTE, 1.8 * boost, {cap: 1, join: 0});
        cr.newPath();
        ellipsePath(cr, -1.7, 0.5, 2.3, 2.3);
        fillWith(cr, NOTE);
        cr.restore();
        break;
    case 'unplugged':
        cr.newPath();
        ellipsePath(cr, 86, 16, 9, 9);
        fillWith(cr, hex(0x3A3F44));
        cr.newPath();
        segmentsPath(cr, [[80.5, 19, 83.5, 16], [88.5, 16, 91.5, 13], [82, 12, 90, 20]]);
        stroke(hex(0xC9D1D4), 2);
        break;
    case 'sparkle':
        cr.save();
        cr.translate(88, 15);
        sparklePath(cr, 9);
        fillWith(cr, AMBER);
        cr.restore();
        break;
    case 'pause':
        disc();
        stroke(NOTE, 1.8);
        cr.newPath();
        segmentsPath(cr, [[83.5, 12.5, 83.5, 19.5], [88.5, 12.5, 88.5, 19.5]]);
        stroke(NOTE, 2.2);
        break;
    default:
        throw new Error(`no such badge: ${badge}`);
    }
}
