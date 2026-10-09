// How Kapa looks about, blinks and moves — ports of `KapaGaze`, `KapaBlink`
// and `KapaMotion` in `linux/crates/core/src/kapa/`. Plain functions of time, so
// each can be checked at a moment; `test/fixtures/kapa.json`, written from
// the Rust side, pins the numbers.

const TAU = 2 * Math.PI;
const clamp = (v, lo, hi) => Math.min(Math.max(v, lo), hi);

// MARK: - Where the eyes sit

/**
 * The eyes are drawn as if on a sphere, so a turn of the head moves them round
 * the body and narrows the one turning away. In the drawing's own units: a
 * 100-unit square, y down, the face centred at (52, 60), the eyes 11 either
 * side.
 */
export const KapaGaze = {
    faceX: 52,
    faceY: 60,
    radiusX: 40,
    radiusY: 30,
    spread: 0.28,

    /** One eye: `side` is -1 for the left, 1 for the right. */
    eye(side, look) {
        const turn = side * this.spread + look.yaw;
        const facing = Math.cos(turn) * Math.cos(look.pitch);
        return {
            x: this.faceX + Math.sin(turn) * Math.cos(look.pitch) * this.radiusX,
            y: this.faceY - Math.sin(look.pitch) * this.radiusY,
            // Measured against the eye's own resting turn, so looking ahead
            // draws the eye at exactly the size it was drawn.
            scaleX: Math.max(0.18, Math.cos(turn)) / Math.cos(this.spread),
            scaleY: Math.max(0.18, Math.cos(look.pitch)),
            isHidden: facing < 0.04,
        };
    },

    /** How far the mouth and brows move with the head: less than the eyes. */
    features(look) {
        return {dx: Math.sin(look.yaw) * this.radiusX * 0.8, dy: -Math.sin(look.pitch) * this.radiusY * 0.6};
    },
};

// MARK: - Blinking

export const KapaBlink = {
    shortest: 2.2,
    spread: 3.2,
    doubleChance: 0.22,
    doubleGap: 0.23,
    closing: 0.07,
    opening: 0.13,

    /** The wait before the next blink, from a uniform draw in 0...1. */
    delay(draw) { return this.shortest + this.spread * clamp(draw, 0, 1); },
    isDouble(draw) { return draw < this.doubleChance; },
    /** Eyes already shut, or arcs, have no lids to drop. */
    blinks(eyes) { return eyes !== 'happy' && eyes !== 'closed'; },
};

// MARK: - Motion

const easeIn = t => t * t * t;
const easeOut = t => 1 - Math.pow(1 - clamp(t, 0, 1), 3);

const kick = (sx = 1, sy = 1, dy = 0, dx = 0) => ({sx, sy, dy, dx});

export const KapaMotion = {
    /** Moves `value` toward `target` the same distance per second at any frame rate. */
    approach(value, target, base, dt) {
        return value + (target - value) * (1 - Math.pow(base, Math.max(dt, 0)));
    },

    /** One step of a damped spring: the mouth. Returns `{value, velocity}`. */
    spring(value, velocity, target, dt, omega = TAU / 0.25, damping = 0.6) {
        const step = clamp(dt, 0, 0.05);
        const acceleration = omega * omega * (target - value) - 2 * damping * omega * velocity;
        const v = velocity + acceleration * step;
        return {value: value + v * step, velocity: v};
    },

    /** Breathing at rest. Returns `{sx, sy}`. */
    breath(time) {
        const wave = Math.sin(time * 1.8);
        return {sx: 1 - wave * 0.012, sy: 1 + wave * 0.022};
    },

    musicTempo: 104,

    /** Nodding along: a dip on every beat, a sway every two. Returns `{dy, tilt, sy}`. */
    bob(time) {
        // A hair added, so a moment that is a beat lands on it.
        const beats = time * this.musicTempo / 60 + 1e-9;
        const phase = beats - Math.floor(beats);
        const dip = Math.exp(-phase * 7);
        return {dy: dip * 3.2, tilt: Math.sin(beats * Math.PI) * 4, sy: 1 - dip * 0.05};
    },

    /** The lids over a blink begun `elapsed` seconds ago: 1 open, 0.08 shut. */
    lid(elapsed) {
        const closed = 0.08;
        if (elapsed < 0) return 1;
        if (elapsed < KapaBlink.closing)
            return 1 - (1 - closed) * easeIn(elapsed / KapaBlink.closing);
        const opening = elapsed - KapaBlink.closing;
        if (opening < KapaBlink.opening)
            return closed + (1 - closed) * easeOut(opening / KapaBlink.opening);
        return 1;
    },

    /** How long each reaction runs, in seconds. */
    duration(reaction) {
        switch (reaction) {
        case 'nod': return 0.35;
        case 'gulp': return 0.5;
        case 'hop': return 0.45;
        default: return 0;
        }
    },

    /** The reaction's kick `elapsed` seconds in; null once it is over. */
    kick(reaction, elapsed) {
        const length = this.duration(reaction);
        if (!(elapsed >= 0 && elapsed < length)) return null;
        const p = elapsed / length;
        const wave = Math.sin(p * Math.PI);
        switch (reaction) {
        case 'nod':
            return kick(1, 1 - wave * 0.07, wave * 1.5);
        case 'gulp': {
            const squash = Math.sin(p * TAU) * (1 - p);
            return kick(1 + squash * 0.08, 1 - squash * 0.1);
        }
        case 'hop': {
            const up = Math.sin(p * Math.PI);
            const land = p > 0.75 ? Math.sin((p - 0.75) / 0.25 * Math.PI) : 0;
            return kick(1 + land * 0.06, 1 + up * 0.04 - land * 0.08, -up * 9);
        }
        default: return null;
        }
    },

    boopLength: 0.42,
    boop(elapsed) {
        if (!(elapsed >= 0 && elapsed < this.boopLength)) return null;
        const p = elapsed / this.boopLength;
        const squash = Math.sin(p * 3 * Math.PI) * Math.pow(1 - p, 1.5);
        return kick(1 + squash * 0.16, 1 - squash * 0.2);
    },

    shakeLength: 0.45,
    shake(elapsed) {
        if (!(elapsed >= 0 && elapsed < this.shakeLength)) return null;
        const p = elapsed / this.shakeLength;
        return kick(1, 1, 0, Math.sin(p * 4 * Math.PI) * 3 * (1 - p));
    },

    /** How far Kapa opens its mouth for a file held over the Shelf. */
    appetite(distance, reach) {
        const near = 1 - clamp(distance / Math.max(reach, 1), 0, 1);
        return 0.35 + 0.65 * near * near;
    },

    gulpLength: 1.3,

    /**
     * Kapa eating a dropped file, `elapsed` seconds after the drop; null once
     * over. `{mouth, file (0..1 or null once inside), kick, pleased}`.
     */
    gulp(elapsed) {
        if (!(elapsed >= 0 && elapsed < this.gulpLength)) return null;
        if (elapsed < 0.28) {
            const p = elapsed / 0.28;
            return {mouth: 0.6 + 0.4 * easeOut(p), file: easeIn(p), kick: kick(1, 1 + 0.04 * p), pleased: false};
        }
        if (elapsed < 0.38) {
            const p = (elapsed - 0.28) / 0.1;
            return {mouth: 1 - easeIn(p), file: null, kick: kick(1 + 0.1 * p, 1 - 0.12 * p), pleased: false};
        }
        if (elapsed < 1.0) {
            const p = (elapsed - 0.38) / 0.62;
            const chew = Math.abs(Math.sin(p * 3 * Math.PI));
            return {mouth: chew * 0.25, file: null, kick: kick(1 + chew * 0.05, 1 - chew * 0.07), pleased: true};
        }
        const p = (elapsed - 1.0) / (this.gulpLength - 1.0);
        return {mouth: 0, file: null, kick: kick(1, 1 + Math.sin(p * Math.PI) * 0.03), pleased: true};
    },
};

export const KICK_NONE = kick();
