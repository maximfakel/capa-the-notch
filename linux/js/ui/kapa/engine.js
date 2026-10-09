// Kapa's state between frames and the frame it draws — a port of `KapaEngine`
// in Sources/CapacityNotch/KapaView.swift. Pure motion is in `motion.js`; this
// keeps the clock and the inputs.
//
// Time is seconds on any monotonic clock the host likes, handed in with every
// call; nothing here reads a clock, and random draws come from `random`, so a
// frame is a function of what it was given.

import {LOOK, faceEquals, faceOf} from './face.js';
import {KapaBlink, KapaGaze, KapaMotion} from './motion.js';
import {
    drawBadge, drawBrows, drawEye, drawHeadphones, drawMouth, drawOpenMouth, drawParticle, fillBody, fillCheeks,
    fillShadow, fillShine, strokeBody,
} from './paths.js';

/** The canvas is this much larger than Kapa, centred on it, for what floats off. */
export const OVERHANG = 1.7;

/** Kapa draws thirty times a second while anything on it moves. */
const FRAME = 1 / 30;

const clamp = (value, limit) => Math.min(Math.max(value, -limit), limit);
/**
 * How far each sign reaches above the point it floats from, in Kapa's units at
 * its own size, with room for the edge's smoothing: the note's stem is tallest.
 */
const SIGN_TOP = {note: 15, heart: 4.5, sparkle: 6, sweat: 5, sleep: 4};
const WANDERS = new Set(['rest', 'focused', 'curious', 'stale', 'paused']);
const ALWAYS_MOVING = new Set(['music', 'listening', 'thinking', 'dropReady']);

/**
 * What `swallowedAt` is compared by: a `Date` (or anything with a primitive
 * `valueOf`) by its value, so the same drop handed in again as a new object is
 * still the same drop; null or undefined for none.
 */
function swallowIdentity(value) {
    if (value === undefined || value === null) return null;
    if (typeof value === 'number' && Number.isNaN(value)) return null; // never equal to itself
    if (typeof value === 'object' && typeof value.valueOf === 'function') {
        const primitive = value.valueOf();
        if (primitive !== value && (typeof primitive !== 'object' || primitive === null)) return primitive;
    }
    return value;
}

export class KapaEngine {
    /** @param {{random?: () => number}} [options] */
    constructor({random = Math.random} = {}) {
        this.random = random;
        /** Where Kapa stands, in the surface's coordinates: `{x, y, width, height}`; null unknown. */
        this.frame = null;
        /** The pointer over Kapa, in its own square: `{x, y}`, or null. */
        this.hover = null;
        /** A file being dragged near, in the surface's coordinates, or null. */
        this.dragPoint = () => null;

        /** The face being drawn; null before the first step. */
        this.shown = null;
        this.expression = 'rest';
        this._last = null;
        this._now = 0;
        this._moving = false;
        /** The side Kapa was last stepped at: its own square, whatever it is shown at. */
        this._size = 100;

        this._yaw = 0;
        this._pitch = 0;
        this._tilt = 0;
        this._sx = 1;
        this._sy = 1;
        this._dy = 0;
        this._mouth = 0;
        this._mouthVelocity = 0;

        this._blinkAt = -10;
        this._secondBlinkAt = null;
        this._nextBlink = 0;
        this._swapping = false;
        /** Whether it has ever moved: one never moved is drawn exactly as posed. */
        this._hasMoved = false;

        this._reaction = null; // {kind, at}
        this._boopAt = -10;
        this._shakeAt = -10;
        this._gulpAt = null;
        this._lastSwallow = null;
        this._lastSwallowAt = null;

        this._hoverSince = null;
        this._pleasedUntil = 0;
        this._lastPleased = -10;

        this._settledAt = LOOK.ahead;
        this._bodyTarget = {tilt: 0, sx: 1, sy: 1, dy: 0};
        this._mouthTarget = 0;

        this._wander = LOOK.ahead;
        this._nextWander = 0;
        this._nextAmbient = 0;
        this._particles = [];
    }

    /** A tap: squashed flat, a giggle with the eyes shut, and back. */
    boop() {
        this._boopAt = this._now;
    }

    // MARK: Stepping

    /**
     * One frame's worth of thinking.
     *
     * @param {number} time seconds, monotonic
     * @param {object} inputs
     * @param {string} inputs.expression one of `EXPRESSIONS`
     * @param {number} inputs.size the side Kapa is stepped and drawn at — its own
     * square, which `hover` is measured in and a dragged file's reach is three
     * of. A Kapa shown scaled (the Shelf's drop Kapa, drawn at 98 and shrunk
     * to 34 at rest) is stepped at the size it is drawn at, not shown at.
     * @param {{yaw: number, pitch: number}} [inputs.look] where to look, when the place decides it
     * @param {boolean} [inputs.showsBadge] false where something else already says it
     * @param {number} [inputs.level] a live level, 0 to 1: the microphone's
     * @param {*} [inputs.swallowedAt] which file was last dropped for Kapa to eat: any
     * value that changes with each drop (epoch ms, a `Date`), compared, never read
     * as a time — the gulp starts on this engine's own clock when it changes
     * @param {boolean} [inputs.moving] false where Kapa should hold still: off its
     * page, under Reduce Motion. It is then drawn as it stands, one frame, and
     * `nextFrame` says not to draw again
     */
    step(time, inputs) {
        const dt = Math.min(0.05, Math.max(0, time - (this._last ?? time)));
        this._last = time;
        this._now = time;
        this._moving = inputs.moving ?? true;
        this._size = inputs.size;

        const face = this._faceFor(inputs);
        const expression = inputs.expression;
        const differs = this.shown === null || !faceEquals(this.shown, face) || this.expression !== expression;

        // A new pose arrives inside a blink: the lids shut, the face changes
        // behind them, and they open on the new one — never a melt from one
        // expression into another.
        let changedStill = false;
        if (this.shown === null || !this._moving) {
            if (differs) {
                this._enter(face, expression, true);
                changedStill = true;
            }
        } else if (differs) {
            if (!this._swapping) {
                this._swapping = true;
                this._blinkAt = time;
            }
            if (KapaMotion.lid(time - this._blinkAt) < 0.3 || time - this._blinkAt > KapaBlink.closing + KapaBlink.opening)
                this._enter(face, expression, false);
        }
        const shown = this.shown;
        if (shown === null) return;

        // A drop is eaten when the drop changes, not when it is there: the
        // same one handed in every frame is eaten once.
        const swallowed = swallowIdentity(inputs.swallowedAt);
        if (swallowed !== null && swallowed !== this._lastSwallow) {
            this._lastSwallow = swallowed;
            if (this._moving) {
                this._gulpAt = time;
                this._lastSwallowAt = time;
            }
        }
        if (this._gulpAt !== null && time - this._gulpAt > KapaMotion.gulpLength) {
            this._gulpAt = null;
            this._emit('sparkle', 2);
        }

        if (!this._moving) {
            this._settle(shown, changedStill || !this._hasMoved);
            return;
        }
        this._hasMoved = true;

        this._blinkIfDue(shown);
        this._followTheEyes(shown, inputs, dt);
        this._moveTheBody(shown, inputs, dt);
        this._moveTheMouth(inputs, dt);
        this._noticeThePointer();
        this._emitAmbient();
        this._particles = this._particles.filter(p => time - p.born <= p.life);
    }

    _faceFor(inputs) {
        const face = {...faceOf(inputs.expression)};
        if (inputs.look) face.look = inputs.look;
        if (inputs.showsBadge === false) face.badge = 'none';
        return face;
    }

    _enter(face, expression, quietly) {
        this.shown = face;
        this.expression = expression;
        this._swapping = false;
        if (quietly) return;
        this._reaction = {kind: face.reaction, at: this._now};
        switch (expression) {
        case 'hello':
        case 'inserted': this._emit('sparkle', 3); break;
        case 'failed': this._shakeAt = this._now; break;
        default: break;
        }
    }

    /**
     * Held still. A pose that changed is drawn as it stands; one already shown
     * keeps the body where it was, its eyes open and nothing in the air — a
     * page sliding away goes still rather than snapping back to rest in view
     * as it leaves.
     */
    _settle(face, snap) {
        if (snap) {
            this._yaw = face.look.yaw;
            this._pitch = face.look.pitch;
            this._tilt = face.tilt;
            this._sx = 1;
            this._sy = 1;
            this._dy = 0;
        }
        this._swapping = false;
        this._mouth = 0;
        this._mouthVelocity = 0;
        this._particles = [];
        this._hoverSince = null;
        this._reaction = null;
        this._gulpAt = null;
        this._boopAt = -10;
        this._shakeAt = -10;
        this._blinkAt = -10;
    }

    _range(lo, hi) {
        return lo + (hi - lo) * this.random();
    }

    _blinkIfDue(face) {
        if (this._secondBlinkAt !== null && this._now >= this._secondBlinkAt) {
            this._secondBlinkAt = null;
            this._blinkAt = this._now;
        }
        if (this._now < this._nextBlink) return;
        this._nextBlink = this._now + KapaBlink.delay(this.random());
        if (!KapaBlink.blinks(face.eyes) || this._gulpAt !== null) return;
        this._blinkAt = this._now;
        if (KapaBlink.isDouble(this.random())) this._secondBlinkAt = this._now + KapaBlink.doubleGap;
    }

    /**
     * Where the eyes go: to the pointer over Kapa, to a file being dragged
     * near, sweeping while dictation is recognised, glancing about now and then
     * at rest — and otherwise where the pose looks.
     */
    _followTheEyes(face, inputs, dt) {
        let target = {...face.look};
        const size = inputs.size;
        const drag = this.expression === 'dropReady' ? this.dragPoint() : null;
        if (this.hover) {
            target = {
                yaw: clamp((this.hover.x - size / 2) / size * 1.3, 0.5),
                pitch: clamp((size / 2 - this.hover.y) / size + 0.08, 0.4),
            };
        } else if (drag && this.frame) {
            // Coucou's look: tanh of the distance, so a far file still pulls the
            // eyes and a near one does not throw them round the head.
            const across = drag.x - (this.frame.x + this.frame.width / 2);
            const up = (this.frame.y + this.frame.height / 2) - drag.y;
            target = {yaw: Math.tanh(across / 120) * 0.55, pitch: Math.tanh(up / 90) * 0.4};
        } else if (this.expression === 'thinking') {
            target.yaw += Math.sin(this._now * 2.6) * 0.16;
        } else if (WANDERS.has(this.expression)) {
            if (this._now >= this._nextWander) {
                this._nextWander = this._now + this._range(2.5, 6);
                this._wander = this.random() < 0.4
                    ? LOOK.ahead
                    : {yaw: this._range(-0.18, 0.18), pitch: this._range(-0.06, 0.1)};
            }
            target.yaw += this._wander.yaw;
            target.pitch += this._wander.pitch;
        }
        this._settledAt = target;
        this._yaw = KapaMotion.approach(this._yaw, target.yaw, 0.0025, dt);
        this._pitch = KapaMotion.approach(this._pitch, target.pitch, 0.0025, dt);
    }

    _moveTheBody(face, inputs, dt) {
        let targetTilt = face.tilt;
        let loopSX = 1;
        let loopSY = 1;
        let loopDY = 0;
        switch (this.expression) {
        case 'music': {
            const bob = KapaMotion.bob(this._now);
            loopDY = bob.dy;
            loopSY = bob.sy;
            targetTilt += bob.tilt;
            break;
        }
        case 'listening': {
            const level = Math.min(Math.max(inputs.level ?? 0, 0), 1);
            loopSY = 1 + level * 0.08;
            loopSX = 1 - level * 0.03;
            loopDY = -level * 2.5;
            targetTilt += level * 6;
            break;
        }
        case 'dropReady': {
            // Leaning towards the file, a little up on its toes.
            const point = this.dragPoint();
            if (point && this.frame)
                targetTilt += Math.tanh((point.x - (this.frame.x + this.frame.width / 2)) / 120) * 7;
            loopSY = 1.04;
            break;
        }
        default:
            // At rest Kapa holds still between its blinks and glances, so the
            // timeline can rest with it; breathing would keep it drawing.
            break;
        }
        this._bodyTarget = {tilt: targetTilt, sx: loopSX, sy: loopSY, dy: loopDY};
        // The music's dip and sway are curves of their own; following them
        // would only blunt them.
        if (this.expression === 'music') {
            this._tilt = targetTilt;
            this._sy = loopSY;
            this._dy = loopDY;
            this._sx = 1;
        } else {
            this._tilt = KapaMotion.approach(this._tilt, targetTilt, 0.0008, dt);
            this._sx = KapaMotion.approach(this._sx, loopSX, 0.0008, dt);
            this._sy = KapaMotion.approach(this._sy, loopSY, 0.0008, dt);
            this._dy = KapaMotion.approach(this._dy, loopDY, 0.0008, dt);
        }
    }

    _moveTheMouth(inputs, dt) {
        let target = 0;
        if (this._gulpAt !== null) {
            // The gulp has the mouth; the spring waits, shut.
            this._mouth = 0;
            this._mouthVelocity = 0;
            return;
        }
        if (this.expression === 'dropReady') {
            const point = this.dragPoint();
            if (this._lastSwallowAt !== null && this._now - this._lastSwallowAt < KapaMotion.gulpLength + 1) {
                target = 0;
            } else if (point && this.frame) {
                const distance = Math.hypot(
                    point.x - (this.frame.x + this.frame.width / 2),
                    point.y - (this.frame.y + this.frame.height / 2));
                target = KapaMotion.appetite(distance, inputs.size * 3);
            } else {
                target = 0.5;
            }
        } else if (this.expression === 'listening') {
            target = Math.min(Math.max(inputs.level ?? 0, 0), 1) * 0.35;
        }
        this._mouthTarget = target;
        const spring = KapaMotion.spring(this._mouth, this._mouthVelocity, target, dt);
        this._mouth = Math.max(0, spring.value);
        this._mouthVelocity = spring.velocity;
    }

    /**
     * The pointer arriving draws a blink and a nod; left resting there for a
     * moment it pleases Kapa, at most every six seconds.
     */
    _noticeThePointer() {
        if (!this.hover) {
            this._hoverSince = null;
            return;
        }
        if (this._hoverSince === null) {
            this._hoverSince = this._now;
            this._blinkAt = this._now;
            this._reaction = {kind: 'nod', at: this._now};
            return;
        }
        if (this._now - this._hoverSince > 1.9 && this._now - this._lastPleased > 6) {
            this._lastPleased = this._now;
            this._pleasedUntil = this._now + 1.4;
            this._emit('heart', 3);
        }
    }

    _emitAmbient() {
        if (this._now < this._nextAmbient) return;
        switch (this.expression) {
        case 'music':
            this._nextAmbient = this._now + 1.3;
            this._emit('note', 1);
            break;
        case 'worried':
            this._nextAmbient = this._now + 2.6;
            this._emit('sweat', 1);
            break;
        case 'waiting':
            this._nextAmbient = this._now + 1.8;
            this._emit('sleep', 1);
            break;
        default:
            this._nextAmbient = this._now + 1;
        }
    }

    _emit(kind, count) {
        for (let index = 0; index < count; index++) {
            let x;
            let y;
            switch (kind) {
            case 'note': [x, y] = [82, 26]; break;
            case 'heart': [x, y] = [this._range(30, 74), 22]; break;
            case 'sparkle': [x, y] = [this._range(20, 84), this._range(14, 40)]; break;
            case 'sweat': [x, y] = [78, 40]; break;
            default: [x, y] = [74, 22]; break; // sleep
            }
            this._particles.push({
                kind,
                born: this._now + index * 0.14,
                life: kind === 'sparkle' ? 0.7 : this._range(1.3, 1.8),
                x, y,
                drift: this._range(-6, 6),
            });
        }
    }

    // MARK: When to draw next

    /**
     * The next moment worth drawing after `time`: the next frame while anything
     * moves, else whatever is due next — a blink, a glance, a note. A Kapa at
     * rest costs a few frames every few seconds, not thirty a second.
     */
    nextFrame(time) {
        // Not running — held still, off its page, under Reduce Motion — it is
        // drawn once and not again until something changes (`KapaSchedule`
        // ends its timeline).
        if (!this._moving || this.shown === null) return Infinity;
        if (this.isMoving(time)) return time + FRAME;
        let due = this._nextBlink;
        if (this._secondBlinkAt !== null) due = Math.min(due, this._secondBlinkAt);
        if (WANDERS.has(this.expression)) due = Math.min(due, this._nextWander);
        if (this.expression === 'worried' || this.expression === 'waiting') due = Math.min(due, this._nextAmbient);
        return Math.max(time + FRAME, due);
    }

    isMoving(time) {
        if (!this._moving || this.shown === null) return false;
        // Moving for as long as they last.
        if (ALWAYS_MOVING.has(this.expression)) return true;
        if (this.hover || this._swapping || this._gulpAt !== null || this._particles.length > 0) return true;
        if (time - this._blinkAt < KapaBlink.closing + KapaBlink.opening + FRAME) return true;
        if (time < this._pleasedUntil || time - this._boopAt < 0.8 || time - this._shakeAt < KapaMotion.shakeLength) return true;
        if (this._reaction && time - this._reaction.at < KapaMotion.duration(this._reaction.kind) + FRAME) return true;
        // Still on its way to where it is going.
        const near = 0.002;
        return Math.abs(this._yaw - this._settledAt.yaw) > near || Math.abs(this._pitch - this._settledAt.pitch) > near
            || Math.abs(this._tilt - this._bodyTarget.tilt) > 0.05 || Math.abs(this._sx - this._bodyTarget.sx) > near
            || Math.abs(this._sy - this._bodyTarget.sy) > near || Math.abs(this._dy - this._bodyTarget.dy) > 0.02
            || Math.abs(this._mouth - this._mouthTarget) > 0.01 || Math.abs(this._mouthVelocity) > 0.05;
    }

    // MARK: Drawing

    /**
     * Draws Kapa with the context's origin at the top left of its `size`
     * square (not of the larger canvas around it: what floats off Kapa is
     * drawn beyond the square, and the host leaves room).
     *
     * @param {object} cr a Cairo-style context
     * @param {{size?: number, outline?: number[]}} options `size`: the side to draw at, by
     * default the one it was stepped at; `outline`: `[r, g, b, a?]`, a ring of
     * the background's colour round the body
     */
    draw(cr, {size = this._size, outline = null} = {}) {
        const face = this.shown;
        if (face === null) return;
        const scale = size / 100;
        const boost = size < 32 ? 1.5 : 1;
        const now = this._now;

        cr.save();
        cr.scale(scale, scale);

        const gulp = this._gulpAt !== null ? KapaMotion.gulp(now - this._gulpAt) : null;
        const kick = {sx: 1, sy: 1, dy: 0, dx: 0};
        for (const extra of [
            this._reaction ? KapaMotion.kick(this._reaction.kind, now - this._reaction.at) : null,
            KapaMotion.boop(now - this._boopAt),
            KapaMotion.shake(now - this._shakeAt),
            gulp?.kick ?? null,
        ]) {
            if (!extra) continue;
            kick.sx *= extra.sx;
            kick.sy *= extra.sy;
            kick.dy += extra.dy;
            kick.dx += extra.dx;
        }
        const pleased = now < this._pleasedUntil || gulp?.pleased === true || now - this._boopAt < 0.7;

        fillShadow(cr);

        cr.save();
        // Every squash and lean about the middle of the base, where Kapa sits.
        cr.translate(50 + kick.dx, 90 + this._dy + kick.dy);
        cr.rotate((-this._tilt * Math.PI) / 180);
        cr.scale(this._sx * kick.sx, this._sy * kick.sy);
        cr.translate(-50, -90);

        if (outline) strokeBody(cr, outline, 6);
        fillBody(cr);
        fillShine(cr);
        if (face.blush || pleased) fillCheeks(cr);
        if (face.headphones) drawHeadphones(cr);

        const look = {yaw: this._yaw, pitch: this._pitch};
        const lid = KapaMotion.lid(now - this._blinkAt);
        const eyes = pleased && KapaBlink.blinks(face.eyes) ? 'happy' : face.eyes;
        for (const side of [-1, 1]) drawEye(cr, eyes, side, look, lid, boost);

        const shift = KapaGaze.features(look);
        cr.save();
        cr.translate(shift.dx, shift.dy);
        drawBrows(cr, face.brows, boost);
        const open = Math.max(this._mouth, gulp?.mouth ?? 0);
        if (open > 0.06) {
            // An open mouth, as wide as appetite or a gulp has it.
            drawOpenMouth(cr, open);
        } else {
            drawMouth(cr, face.mouth, boost);
        }
        cr.restore();
        cr.restore(); // the body

        // The file going in: from above the head into the mouth, shrinking.
        if (gulp && gulp.file !== null) {
            cr.save();
            cr.translate(16 + (52 - 16) * gulp.file, 12 + (72 - 12) * gulp.file);
            const shrink = 1 - 0.75 * gulp.file;
            cr.scale(shrink, shrink);
            cr.translate(-16, -12);
            drawBadge(cr, 'file', boost);
            cr.restore();
        }

        // Signs stay upright when Kapa leans, and keep away while it eats.
        if (!gulp) drawBadge(cr, face.badge, boost);

        this._drawParticles(cr, boost);
        cr.restore();
    }

    /**
     * How far above the top of her square anything of hers reaches from now
     * until `until` (seconds), in her units (her square is 100 tall); 0 when
     * nothing does. Her body, its squash and her badge keep within the square;
     * signs rise as they go and grow as they fade, the highest as they go out.
     */
    reach(until) {
        let top = 0;
        for (const particle of this._particles) {
            if (particle.born > until) continue;
            const at = Math.min(until, particle.born + particle.life);
            const age = (at - particle.born) / particle.life;
            const rise = Math.max(0, (at - particle.born) * (particle.kind === 'sweat' ? -14 : 22));
            top = Math.min(top, particle.y - rise - SIGN_TOP[particle.kind] * (1 + age * 0.4));
        }
        return Math.max(0, -top);
    }

    _drawParticles(cr, boost) {
        const now = this._now;
        for (const particle of this._particles) {
            if (now < particle.born) continue;
            const age = (now - particle.born) / particle.life;
            const alpha = age < 0.2 ? age / 0.2 : 1 - (age - 0.2) / 0.8;
            const rise = (now - particle.born) * (particle.kind === 'sweat' ? -14 : 22);
            let x = particle.x + particle.drift * age;
            if (particle.kind === 'heart') x += Math.sin((now - particle.born) * 6) * 2.5;
            cr.save();
            cr.translate(x, particle.y - rise);
            const grow = 1 + age * 0.4;
            cr.scale(grow, grow);
            drawParticle(cr, particle.kind, boost, Math.max(0, alpha));
            cr.restore();
        }
    }
}
