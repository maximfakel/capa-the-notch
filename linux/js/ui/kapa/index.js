// Kapa, the surface's character (ADR 0006): its poses, motion and drawing,
// written once against the Cairo-style context.

import {KapaEngine} from './engine.js';

export {CairoGjs} from './cairo-gjs.js';
export {OVERHANG, KapaEngine} from './engine.js';
export {EXPRESSIONS, KAPA_PREFERENCE, LOOK, faceEquals, faceOf} from './face.js';
export {capacityFocus, capacityMood, musicMood, urgency} from './mood.js';
export {KapaBlink, KapaGaze, KapaMotion} from './motion.js';

/**
 * Draws Kapa with the context's origin at the top left of the square it is
 * shown in: `drawnAt` wide, or `size` when that is not given.
 *
 * Kapa moves, so a Kapa that is drawn more than once keeps an engine between
 * frames and hands it back each time (`engine`); `engine.nextFrame(t)` says
 * when to draw next. Without one, Kapa is drawn exactly as posed.
 *
 * @param {object} cr a Cairo-style context (`CairoCanvas`, or `CairoGjs`)
 * @param {object|null} gfx the surface's text/measure object; Kapa draws no text, so it is unused
 * @param {object} options
 * @param {string} options.expression one of `EXPRESSIONS`
 * @param {number} options.size the side Kapa is stepped and drawn at, in the surface's units
 * @param {number} [options.drawnAt] the side it is shown at, when that is not `size`: the
 * drawing at `size` scaled to it, as SwiftUI's `scaleEffect` scales a `KapaView` — the
 * Shelf's drop Kapa is drawn at 98 and shown from 34 up. Strokes are not made bolder for
 * a small `drawnAt`; `hover` is measured at `size`
 * @param {number} [options.t] seconds on any monotonic clock
 * @param {boolean} [options.awake] whether the place Kapa stands is on screen now
 * @param {KapaEngine} [options.engine] the Kapa's state between frames
 * @param {boolean} [options.isAnimated] false where Kapa should hold still whatever is true
 * @param {{yaw: number, pitch: number}} [options.look] where to look, when the place decides it
 * @param {boolean} [options.showsBadge] false where something else already says it
 * @param {number[]} [options.outline] a ring of the background's colour round the body
 * @param {number} [options.level] a live level, 0 to 1: the microphone's
 * @param {*} [options.swallowedAt] which file was last dropped for Kapa to eat: a value that
 * changes with each drop (epoch ms, as the Shelf's view has it), not a time on `t`'s clock
 * @param {boolean} [options.stepped] the engine is already stepped to `t`: drawn as it is, again
 * @returns {KapaEngine} the engine used, to hand back next frame
 */
export function drawKapa(cr, gfx, options) {
    const {
        expression, size, drawnAt = size, t = 0, awake = true, isAnimated = true, engine = new KapaEngine(),
        look, showsBadge, outline, level, swallowedAt, stepped = false,
    } = options;
    if (!stepped)
        engine.step(t, {expression, size, look, showsBadge, level, swallowedAt, moving: isAnimated && awake});
    // Shown at nothing, nothing is drawn: Cairo will not scale by zero.
    if (!(drawnAt > 0)) return engine;
    if (drawnAt === size) {
        engine.draw(cr, {size, outline});
    } else {
        cr.save();
        cr.scale(drawnAt / size, drawnAt / size);
        engine.draw(cr, {size, outline});
        cr.restore();
    }
    return engine;
}
