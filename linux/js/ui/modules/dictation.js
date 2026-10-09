// The Dictation Capsule (`DictationCapsule` and `DictationPanelController` in
// DictationPanel.swift): a temporary indicator under the Notch Surface — the
// orb centred twelve points below it, Kapa beside it to the right, a tap on an
// outcome with something to say opening its details.
//
// Everything about its size and look is decided in `capa_core::dictation::
// capsule` and arrives in the Module's state (`orb`, `kapa`, `details`, …);
// this file puts it where the Swift puts it.

import {Type} from '../metrics.js';
import {MurmurClock, drawOrb} from './orb.js';
import {t} from '../strings.js';
import {PRESSED_OPACITY, isPressed} from '../widgets.js';
import {sameValue} from '../model.js';

// capsule.rs
export const ORB = 100;
export const MARGIN = 16;
export const KAPA_SIZE = 136;
export const GAP = 6;
export const BELOW_SURFACE = 12;
const KAPA_LOOK = {yaw: -0.3, pitch: 0.12};

/** The orb alone, or the orb and Kapa side by side, tops level. */
export function capsuleSize(showsKapa) {
    return showsKapa ? {width: ORB + GAP + KAPA_SIZE, height: KAPA_SIZE} : {width: ORB, height: ORB};
}

const POPOVER = {width: 310, padding: 18, radius: 10, gap: 12, arrowWidth: 24, arrowHeight: 11};

/** `.shadow(color: .black.opacity(0.2), radius: 9, y: 5)` on the whole capsule (capsule.rs). */
const SHADOW = {opacity: 0.2, radius: 9, y: 5};
/** Cairo's operators, by number (`cairo_operator_t`). */
const OPERATOR_OVER = 2, OPERATOR_ATOP = 5;
/**
 * A blur of radius 9 approximated by taps: the centre and two rings, weights
 * summing to one, so the shadow is as dark as one painted at 20% and as soft
 * as a gaussian of about that size.
 */
const SHADOW_TAPS = (() => {
    const taps = [[0, 0, 0.22]];
    for (const [r, n, w] of [[SHADOW.radius * 0.35, 6, 0.48], [SHADOW.radius * 0.7, 8, 0.30]]) {
        for (let i = 0; i < n; i++) {
            const a = (i + (r > 4 ? 0.5 : 0)) * 2 * Math.PI / n;
            taps.push([r * Math.cos(a), r * Math.sin(a), w / n]);
        }
    }
    return taps;
})();

/**
 * The capsule's clock: the orb's phase starts at zero when the capsule
 * appears (`MurmurView`'s birth), and entries (wake, swell, stutter) play from
 * each change. A hidden capsule is gone, so its next appearance starts afresh.
 */
function capsuleClock(scene, presentation) {
    const d = scene.dictation ??= {presentation: null, details: false, clock: null};
    if (d.presentation !== presentation) {
        if (d.presentation === null || d.presentation === 'hidden' || !d.clock)
            d.clock = new MurmurClock();
        d.presentation = presentation;
        d.details = false;
    }
    return d.clock;
}

/** The orb's half of the shadow: its opaque disc (r 50), blurred, five points down. */
function drawOrbShadow(g, x, y) {
    const cx = x + ORB / 2, cy = y + ORB / 2 + SHADOW.y;
    const inner = ORB / 2 - SHADOW.radius, outer = ORB / 2 + SHADOW.radius;
    g.cr.setSourceRadial(cx, cy, inner, cx, cy, outer, [
        [0, 0, 0, 0, SHADOW.opacity * g.alpha], [1, 0, 0, 0, 0],
    ]);
    g.cr.newPath();
    g.cr.moveTo(cx + outer, cy);
    g.cr.arc(cx, cy, outer, 0, 2 * Math.PI);
    g.cr.closePath();
    g.cr.fill();
}

/**
 * The shadow of whatever `draw` draws (Kapa): drawn into a group five points
 * down, turned black where it covers, and painted at 20% — through the taps
 * of a blur where the context can paint a group more than once. The group is
 * no larger than `room` (`{x, y, w, h}`), where all of the shadow falls: it is
 * painted fifteen times.
 */
function drawShadowOf(g, draw, room) {
    const cr = g.cr;
    if (![cr.pushGroup, cr.setOperator, cr.paint, cr.paintWithAlpha].every(f => typeof f === 'function'))
        return;
    const reuse = typeof cr.popGroup === 'function' && typeof cr.setSource === 'function';
    if (!reuse && typeof cr.popGroupToSource !== 'function')
        return;
    cr.save();
    if (room && cr.rectangle && cr.clip) {
        cr.newPath?.();
        cr.rectangle(room.x, room.y, room.w, room.h);
        cr.clip();
    }
    cr.pushGroup();
    cr.save();
    cr.translate(0, SHADOW.y);
    draw();
    cr.restore();
    // Black wherever it drew, as much as it covered.
    cr.setOperator(OPERATOR_ATOP);
    cr.setSourceRGBA(0, 0, 0, 1);
    cr.paint();
    cr.setOperator(OPERATOR_OVER);
    if (reuse) {
        const silhouette = cr.popGroup();
        for (const [dx, dy, w] of SHADOW_TAPS) {
            cr.save();
            cr.translate(dx, dy);
            cr.setSource(silhouette);
            cr.paintWithAlpha(SHADOW.opacity * w * g.alpha);
            cr.restore();
        }
    } else {
        cr.popGroupToSource();
        cr.paintWithAlpha(SHADOW.opacity * g.alpha);
    }
    cr.restore();
}

/** Whether the popover is dark: the application's appearance, or the system's when it follows it. */
function isDark(scene) {
    const m = scene.model ?? {};
    if (m.appearance === 'light' || m.appearance === 'dark')
        return m.appearance === 'dark';
    return m.systemDark ?? m.dark ?? true;
}

/** An NSPopover's look, light or dark. */
function popoverColours(dark) {
    return dark ? {
        fill: [0x2C / 255, 0x2C / 255, 0x2E / 255],
        border: [1, 1, 1, 0.12],
        title: [1, 1, 1, 0.85],
        body: [1, 1, 1, 0.85],
        button: [1, 1, 1, 0.14], buttonHover: [1, 1, 1, 0.24], buttonBorder: null, buttonText: [1, 1, 1, 0.85],
    } : {
        fill: [0xF2 / 255, 0xF2 / 255, 0xF2 / 255],
        border: [0, 0, 0, 0.12],
        title: [0, 0, 0, 0.85],
        body: [0, 0, 0, 0.85],
        button: [1, 1, 1], buttonHover: [0.93, 0.93, 0.93], buttonBorder: [0, 0, 0, 0.16], buttonText: [0, 0, 0, 0.85],
    };
}

/** The popover's outline: a rounded box with its arrow on the top edge, pointing up at the capsule. */
function popoverPath(cr, x, y, w, h, r, ax) {
    const {arrowWidth: aw, arrowHeight: ah} = POPOVER;
    cr.newPath();
    cr.moveTo(x + r, y);
    cr.lineTo(ax - aw / 2, y);
    cr.lineTo(ax, y - ah);
    cr.lineTo(ax + aw / 2, y);
    cr.lineTo(x + w - r, y);
    cr.arc(x + w - r, y + r, r, -Math.PI / 2, 0);
    cr.lineTo(x + w, y + h - r);
    cr.arc(x + w - r, y + h - r, r, 0, Math.PI / 2);
    cr.lineTo(x + r, y + h);
    cr.arc(x + r, y + h - r, r, Math.PI / 2, Math.PI);
    cr.lineTo(x, y + r);
    cr.arc(x + r, y + r, r, Math.PI, 1.5 * Math.PI);
    cr.closePath();
}

/**
 * The popover a tap opens on an error or a copy (`arrowEdge: .bottom`): under
 * the capsule, centred on it, its arrow at the capsule's bottom edge. Title
 * (`.headline`), the sentence, and its buttons.
 */
function drawPopover(g, scene, x, y, state) {
    const d = state.details;
    const colours = popoverColours(isDark(scene));
    // `.headline`: 13, semibold.
    const titleFont = Type.geist(13, 600), bodyFont = Type.geist(13, 400), buttonFont = Type.geist(13, 500);
    const inner = POPOVER.width - 2 * POPOVER.padding;
    const body = t(d.body);
    // The body wraps; measure it the way the page does.
    const words = body.split(' ');
    const lines = [];
    let line = '';
    for (const w of words) {
        const trial = line ? `${line} ${w}` : w;
        if (g.measureText(trial, bodyFont) <= inner || !line)
            line = trial;
        else {
            lines.push(line);
            line = w;
        }
    }
    if (line)
        lines.push(line);
    const lh = g.lineHeight(bodyFont);
    const buttonH = 22;
    const height = POPOVER.padding * 2 + g.lineHeight(titleFont) + POPOVER.gap + lines.length * lh + POPOVER.gap + buttonH;
    const ax = x + POPOVER.width / 2;
    g.color(colours.fill);
    popoverPath(g.cr, x, y, POPOVER.width, height, POPOVER.radius, ax);
    g.cr.fill();
    g.color(colours.border);
    g.cr.setLineWidth(1);
    popoverPath(g.cr, x + 0.5, y + 0.5, POPOVER.width - 1, height - 1, POPOVER.radius - 0.5, ax);
    g.cr.stroke();
    let cy = y + POPOVER.padding;
    g.drawText(t(d.title), x + POPOVER.padding, cy, titleFont, colours.title);
    cy += g.lineHeight(titleFont) + POPOVER.gap;
    lines.forEach((l, i) => g.drawText(l, x + POPOVER.padding, cy + i * lh, bodyFont, colours.body));
    cy += lines.length * lh + POPOVER.gap;

    let bx = x + POPOVER.padding;
    const button = (id, label, onClick) => {
        const w = g.measureText(label, buttonFont) + 20;
        g.fillRoundRect(bx, cy, w, buttonH, 5, scene.isHovered(id) ? colours.buttonHover : colours.button);
        if (colours.buttonBorder)
            g.strokeRoundRect(bx + 0.5, cy + 0.5, w - 1, buttonH - 1, 4.5, colours.buttonBorder, 1);
        g.drawText(label, bx + 10, cy + (buttonH - g.lineHeight(buttonFont)) / 2, buttonFont, colours.buttonText);
        scene.addHit({id, x: bx, y: cy, w, h: buttonH, onClick, cursor: 'pointer', label});
        bx += w + 8;
    };
    if (d.offersSettings) {
        button('dictation:settings', t('Open Dictation Settings'), () => {
            scene.dictation.details = false;
            scene.actions.call?.('dictation', 'dismiss');
            scene.actions.openSettings?.('dictation');
        });
    }
    button('dictation:dismiss', t('Dismiss'), () => {
        scene.dictation.details = false;
        scene.actions.call?.('dictation', 'dismiss');
    });
    return height;
}

export default {
    id: 'dictation',

    /**
     * The capsule, while there is something to show. `frame` is the panel's
     * (content and margin) for the surface above it: the orb centred under it,
     * twelve points below, Kapa to its right.
     */
    overlay(ctx, {cx, bottom, scene}) {
        const state = ctx.module;
        if (!state?.isDrawn)
            return null;
        const showsKapa = ctx.showsKapa !== false;
        const size = capsuleSize(showsKapa);
        // Anchored to where the surface is going, not where its animation is
        // (`DictationPanelController.anchor(to:)` takes the surface's frame).
        const surfaceBottom = scene.height?.target ?? bottom;
        const x = cx - ORB / 2, y = surfaceBottom + BELOW_SURFACE;
        const frame = {x: x - MARGIN, y: y - MARGIN, width: size.width + 2 * MARGIN, height: size.height + 2 * MARGIN};
        // The popover, centred on the whole capsule.
        const popoverX = x + size.width / 2 - POPOVER.width / 2;
        if (scene.dictation?.details && state.details) {
            const left = Math.min(frame.x, popoverX), right = Math.max(frame.x + frame.width, popoverX + POPOVER.width);
            frame.x = left;
            frame.width = right - left;
            frame.height += 12 + 160; // room for the popover under it
        }
        // What the capsule may take of a layer of its own: its panel without the
        // popover, from where the top bar ends — the margin reaches a few points into
        // the bar under a closed surface, and nothing is drawn there.
        const bar = scene.geometry?.barHeight ?? 0;
        const panel = {x: x - MARGIN, y: y - MARGIN, w: size.width + 2 * MARGIN, h: size.height + 2 * MARGIN};
        const rect = {x: panel.x, y: Math.max(panel.y, bar), w: panel.w, h: panel.y + panel.h - Math.max(panel.y, bar)};

        /** The orb, Kapa and their shadow: all that moves. */
        const drawCapsule = (g, sc) => {
            const clock = capsuleClock(sc, state.presentation);
            const voice = state.followsVoice ? state.level ?? 0 : 0;
            const orb = clock.frame(state.orb.state, sc.now, voice, {reduced: sc.reduced});
            const kapa = () => sc.drawKapaAt(g, 'dictation', x + ORB + GAP, y, KAPA_SIZE, state.kapa, {
                look: KAPA_LOOK, showsBadge: false, level: voice,
                // Its own panel, always on screen; the capsule is the button, so a tap on Kapa is a tap on it.
                awake: true, tappable: false, hoverable: false,
            });

            // The capsule is a plain button: all of it, its shadow too, dims while it is held down.
            const group = g.group ?? g.withAlpha;
            group.call(g, state.hasDetails && isPressed(sc, 'dictation:capsule') ? PRESSED_OPACITY : 1, () => {
                // The shadow under the whole capsule: the orb's disc, and Kapa's own shape.
                drawOrbShadow(g, x, y);
                // Kapa's shadow: her square and the margin round it, as far as the panel goes.
                if (showsKapa)
                    drawShadowOf(g, kapa, {x: x + ORB + GAP - MARGIN, y: y - MARGIN, w: KAPA_SIZE + 2 * MARGIN, h: KAPA_SIZE + 2 * MARGIN});

                drawOrb(g, x, y, ORB, {state: state.orb.state, tone: state.orb.tone, tone2: state.orb.tone2, ...orb});
                // Kapa beside the orb, looking at it: it listens, thinks, nods at what went in, is puzzled at what did not.
                if (showsKapa)
                    kapa();
            });
        };

        /**
         * The capsule, where it may go on the host's layer, as one picture of its own in
         * its panel (`Gfx.isolated`), on the surface as on the layer, so the two are the
         * same to the last bit when one hands it to the other; and every group drawn in
         * it (Kapa's shadow) is no larger than the panel. On the layer, the next frame is
         * the layer's, every frame while it moves.
         */
        const drawMoving = (g, sc, onLayer = false) => {
            if (sc.liveLayers && g.isolated)
                g.isolated(rect.x, rect.y, rect.w, rect.h, () => drawCapsule(g, sc));
            else
                drawCapsule(g, sc);
            if (onLayer && !sc.reduced)
                sc.wantFrameAt(sc.now);
        };

        /** Where the capsule and its popover are, and what answers to the pointer and is heard: the surface's. */
        const hits = sc => {
            // Where the capsule and its popover are, for a press that lands elsewhere (`pressedAnywhere`).
            sc.dictation ??= {presentation: null, details: false, clock: null};
            sc.dictation.capsule = {x, y, w: size.width, h: size.height};
            sc.dictation.popover = null;
            // The capsule is a button: a tap opens the details where there are any.
            if (state.hasDetails) {
                sc.addHit({
                    id: 'dictation:capsule', x, y, w: size.width, h: size.height, cursor: 'pointer',
                    label: t(state.accessibilityLabel),
                    onClick: () => { sc.dictation.details = !sc.dictation.details; sc.onChange(); },
                });
            } else {
                // A button with nothing to open is still heard, as what the capsule is doing.
                sc.addLabel?.({id: 'dictation:capsule', x, y, w: size.width, h: size.height, label: t(state.accessibilityLabel)});
            }
        };

        return {
            frame,
            draw(g, sc) {
                drawMoving(g, sc);
                hits(sc);
                // Its details, unless the capsule has just become something else (`capsuleClock`).
                if (sc.dictation?.details && state.details) {
                    const top = y + size.height + 12;
                    const height = drawPopover(g, sc, popoverX, top, state);
                    sc.dictation.popover = {x: popoverX, y: top - POPOVER.arrowHeight, w: POPOVER.width, h: height + POPOVER.arrowHeight};
                }
            },
            // Without its popover, the capsule's moving part may go on a layer of its own.
            layer: scene.dictation?.details && state.details ? null : {rect, draw: (g, sc) => drawMoving(g, sc, true), hits},
        };
    },

    /**
     * The popover is transient (`.popover`): a press anywhere but on it closes it, at once,
     * as it goes down — in the surface or the capsule's panel (`pressedAnywhere`, before
     * anything takes the press), or anywhere else on the screen (`pressedOutside`). A
     * press on the capsule is the capsule's own, which closes it too.
     */
    listensOutside: scene => !!(scene.dictation?.details && scene.dictation.popover),

    pressedAnywhere(scene, px, py) {
        const d = scene.dictation;
        if (!d?.details || !d.popover)
            return false;
        const inside = r => !!r && px >= r.x && px < r.x + r.w && py >= r.y && py < r.y + r.h;
        if (inside(d.popover) || inside(d.capsule))
            return false;
        d.details = false;
        return true;
    },

    pressedOutside(scene) {
        const d = scene.dictation;
        if (!d?.details)
            return false;
        d.details = false;
        return true;
    },

    /**
     * What changes while it records — the voice's level, the seconds left — is only
     * what the capsule's moving part draws: on its layer, that is all drawn again.
     */
    layerOnly(before, after) {
        if (!before || !after)
            return false;
        const keys = new Set([...Object.keys(before), ...Object.keys(after)]);
        return [...keys].every(k => k === 'level' || k === 'remaining' || sameValue(before[k], after[k]));
    },

    // The capsule moves: keep the frames coming while it is drawn — except
    // under Reduce Motion, where the orb is one still frame. On the host's layer,
    // the layer asks for its own frames.
    needsFrames: ctx => !!ctx.module?.isDrawn && ctx.scene?.reduced !== true && !ctx.layers?.has('overlay:dictation'),
};
