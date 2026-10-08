// SwiftUI's animations of one value, as SwiftUI runs them: the value stands
// where the state says (`target`), less what each animation still has to go.
// A spring is the damped oscillator SwiftUI solves in closed form — `response`
// the period of the undamped spring (ω0 = 2π / response), `damping` the damping
// fraction, unit mass — so a frame stands exactly where SwiftUI's would at that
// moment, however late it comes. A spring started while one is moving takes it
// over with its velocity (`shouldMerge`); a timed curve (Reduce Motion's ease)
// is added to whatever still moves, each finishing on its own; a change made
// without animation moves the state and leaves what is moving to finish over it.

/** Where a spring's remainder is `t` seconds on, and how fast it goes: `{x, v}`. */
export function springState(x0, v0, response, damping, t) {
    const w0 = (2 * Math.PI) / response;
    if (damping < 1) {
        const wd = w0 * Math.sqrt(1 - damping * damping);
        const decay = Math.exp(-damping * w0 * t);
        const c = Math.cos(wd * t), s = Math.sin(wd * t);
        const b = (v0 + damping * w0 * x0) / wd;
        return {
            x: decay * (x0 * c + b * s),
            v: decay * ((b * wd - damping * w0 * x0) * c - (x0 * wd + damping * w0 * b) * s),
        };
    }
    if (damping === 1) {
        const decay = Math.exp(-w0 * t);
        const b = v0 + w0 * x0;
        return {x: decay * (x0 + b * t), v: decay * (b - w0 * (x0 + b * t))};
    }
    const root = w0 * Math.sqrt(damping * damping - 1);
    const r1 = -damping * w0 + root, r2 = -damping * w0 - root;
    const c2 = (v0 - r1 * x0) / (r2 - r1), c1 = x0 - c2;
    return {
        x: c1 * Math.exp(r1 * t) + c2 * Math.exp(r2 * t),
        v: c1 * r1 * Math.exp(r1 * t) + c2 * r2 * Math.exp(r2 * t),
    };
}

export class Spring {
    /**
     * `epsilon` is how near counts as there, in the spring's own units: the last
     * frame steps the rest of the way, so it is a part of a point however the value
     * is scaled (a page position is worth the open width, 560 points a page).
     */
    constructor(value = 0, response = 0.42, damping = 0.8, {epsilon = 0.01} = {}) {
        this.value = value;
        this.target = value;
        this.velocity = 0;
        this.response = response;
        this.damping = damping;
        this.epsilon = epsilon;
        /** The spring's own clock, in seconds: it moves on only as it is stepped. */
        this.time = 0;
        /** What is still moving: springs and timed curves, each an offset from `target` going to nothing. */
        this._moves = [];
    }

    /**
     * Moves towards `target` on the given spring (response, damping fraction), from
     * where it stands and as fast as it goes there. `lead` is how long after the last
     * step it was asked for (seconds), so the move starts then and not at the step.
     */
    to(target, response = this.response, damping = this.damping, lead = 0) {
        this.response = response;
        this.damping = damping;
        const at = this.time + Math.max(lead, 0);
        const change = target - this.target;
        this.target = target;
        const last = this._moves[this._moves.length - 1];
        if (last?.spring) {
            // A spring merges with the one moving: what it had left and the change, at its speed.
            const {x, v} = this._at(last, at);
            Object.assign(last, {x0: x - change, v0: v, t0: at, response, damping});
        } else if (change !== 0) {
            this._moves.push({spring: true, x0: -change, v0: 0, t0: at, response, damping});
        }
        this._evaluate();
    }

    /**
     * Moves there in `duration` seconds on a curve, with no spring: what Reduce Motion
     * asks of every move (`easeInOut`, a fifth of a second or less). Added to whatever
     * is still moving, as SwiftUI adds an animation that does not merge.
     */
    tween(target, duration, curve = null, lead = 0) {
        const change = target - this.target;
        this.target = target;
        if (change !== 0) {
            this._moves.push({
                spring: false, delta: -change, t0: this.time + Math.max(lead, 0), duration, curve: curve ?? ease.inOut,
            });
        }
        this._evaluate();
    }

    /** The state changes without animation: whatever is moving finishes over the new place. */
    shift(target) {
        this.target = target;
        this._evaluate();
    }

    /** Jumps there, without motion. */
    set(value) {
        this._moves = [];
        this.value = this.target = value;
        this.velocity = 0;
    }

    get settled() {
        return this._moves.length === 0;
    }

    /** A move's offset from the target and its speed at `at` on the spring's clock. */
    _at(move, at) {
        const t = Math.max(at - move.t0, 0);
        if (move.spring)
            return springState(move.x0, move.v0, move.response, move.damping, t);
        const p = Math.min(t / move.duration, 1);
        const h = 1e-4;
        const slope = p < 1 ? (move.curve(Math.min(p + h, 1)) - move.curve(p)) / h / move.duration : 0;
        return {x: move.delta * (1 - move.curve(p)), v: -move.delta * slope};
    }

    /** Whether a move has come to rest: near and slow on the same scale, or its time is up. */
    _done(move, state) {
        if (!move.spring)
            return this.time - move.t0 >= move.duration;
        const w0 = (2 * Math.PI) / move.response;
        return Math.hypot(state.x, state.v / w0) < this.epsilon;
    }

    _evaluate() {
        let value = this.target, velocity = 0;
        for (const move of this._moves) {
            const {x, v} = this._at(move, this.time);
            value += x;
            velocity += v;
        }
        this.value = value;
        this.velocity = velocity;
    }

    /** Advances by `dt` seconds. Returns whether it is still moving. */
    step(dt) {
        if (this._moves.length === 0) {
            this.value = this.target;
            this.velocity = 0;
            return false;
        }
        this.time += Math.max(dt, 0);
        // Come to rest, a move is over: the frame that says so stands exactly there.
        this._moves = this._moves.filter(move => !this._done(move, this._at(move, this.time)));
        this._evaluate();
        return this._moves.length > 0;
    }
}

/**
 * A CSS-style cubic Bézier from (0, 0) to (1, 1) through (x1, y1) and
 * (x2, y2): `t` is the share of the time gone, the result the share of the way.
 * Solved for x by Newton's method, with bisection where the slope is too flat.
 */
export function cubicBezier(x1, y1, x2, y2) {
    const cx = 3 * x1, bx = 3 * (x2 - x1) - cx, ax = 1 - cx - bx;
    const cy = 3 * y1, by = 3 * (y2 - y1) - cy, ay = 1 - cy - by;
    const sampleX = s => ((ax * s + bx) * s + cx) * s;
    const sampleY = s => ((ay * s + by) * s + cy) * s;
    const slopeX = s => (3 * ax * s + 2 * bx) * s + cx;
    const solve = x => {
        let s = x;
        for (let i = 0; i < 8; i++) {
            const error = sampleX(s) - x;
            if (Math.abs(error) < 1e-6)
                return s;
            const d = slopeX(s);
            if (Math.abs(d) < 1e-6)
                break;
            s -= error / d;
        }
        let lo = 0, hi = 1;
        s = x;
        while (lo < hi) {
            const v = sampleX(s);
            if (Math.abs(v - x) < 1e-6)
                return s;
            if (x > v)
                lo = s;
            else
                hi = s;
            s = (lo + hi) / 2;
            if (hi - lo < 1e-7)
                break;
        }
        return s;
    };
    return t => {
        if (t <= 0)
            return 0;
        if (t >= 1)
            return 1;
        return sampleY(solve(t));
    };
}

/** Easing curves for the fades, as SwiftUI names them: the same cubic Béziers. */
export const ease = {
    out: cubicBezier(0, 0, 0.58, 1),
    in: cubicBezier(0.42, 0, 1, 1),
    inOut: cubicBezier(0.42, 0, 0.58, 1),
};

/** A timed fade: `start(to, duration, delay)`, then read `value` as time passes. */
export class Fade {
    constructor(value = 0) {
        this.value = value;
        this._from = value;
        this._to = value;
        this._begin = 0;
        this._duration = 0;
        this._delay = 0;
        this._curve = ease.out;
    }

    start(to, duration, delay, curve, now) {
        this._from = this.value;
        this._to = to;
        this._begin = now;
        this._duration = duration;
        this._delay = delay;
        this._curve = curve;
    }

    step(now) {
        if (this.value === this._to)
            return false;
        const t = (now - this._begin - this._delay) / this._duration;
        if (t <= 0)
            return true;
        if (t >= 1) {
            this.value = this._to;
            return false;
        }
        this.value = this._from + (this._to - this._from) * this._curve(t);
        return true;
    }
}
