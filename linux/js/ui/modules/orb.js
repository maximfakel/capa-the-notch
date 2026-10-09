// The Dictation Capsule's orb: Murmur's `limn` style — near-dark glass whose
// edge is alive, a travelling arc of rim light that thickens with the voice
// (`mh_limn` in Vendor/Murmur/.../MurmurGlass.metal).
//
// The original is a ray-marched Metal shader. This is the same picture built
// from the same terms — the von Mises head and tail of the arc, the band's
// width, the eased drift of its angle, the state tempos and entries, the
// success lap that closes the ring, the OKLCH rail every colour walks — drawn
// as vector shapes (an ink disc, a dark body with a lit rim, the arc as short
// strokes of varying light, a catchlight) so that it runs on a Cairo or canvas
// context. It is the one place a surface does not draw what macOS does pixel
// for pixel.
//
// The clock is `MurmurView`'s: the tempo is integrated into a phase
// (`MurmurClock`), so a state change crossfades the speed without the arc
// jumping. Murmur restarts the arc on thinking and success only for the styles
// with a settle arc (`MurmurStyle.hasArc`), and limn is not one of them: the
// arc carries on from wherever it is.

const TAU = Math.PI * 2;
const clamp = (v, lo, hi) => Math.min(Math.max(v, lo), hi);
const mix = (a, b, t) => a + (b - a) * t;
const smoothstep = (a, b, x) => {
    const t = clamp((x - a) / (b - a), 0, 1);
    return t * t * (3 - 2 * t);
};

/** The shader's body radius, in the fraction of the frame (`MH_R`). */
const BODY = 0.300;
/** `MH_SPREAD`: how far the spread walks the hue, in radians. */
const MH_SPREAD = 0.50;
/** limn's character (`MurmurStyle.characterDefaults`): rimWidth, travel, innerHint, spread. */
const LIMN = {width: 0.4, travel: 0.5, hint: 0.3, spread: 0.4};
/** Murmur's `ORB_INK`, which the capsule configures. */
export const ORB_INK = [23 / 255, 23 / 255, 23 / 255];

/**
 * What a state is (`MurmurState.seed`): its tempo, light, palette depth, hue
 * walk, and the entry that announces it. `index` is the shader's `stateIndex`.
 */
export const SEEDS = {
    idle: {index: 0, speed: 0.30, glow: 0.65, depth: 0.75, hueShift: 0, entry: null},
    listening: {index: 1, speed: 0.90, glow: 1.10, depth: 1.10, hueShift: 0, entry: null},
    thinking: {index: 2, speed: 1.15, glow: 1.20, depth: 1.25, hueShift: 0, entry: 'wake'},
    responding: {index: 3, speed: 1.45, glow: 1.30, depth: 1.25, hueShift: 0, entry: null},
    success: {index: 4, speed: 0.55, glow: 1.05, depth: 1.00, hueShift: 0, entry: 'swell'},
    error: {index: 5, speed: 0.65, glow: 0.80, depth: 1.20, hueShift: -0.35, entry: 'stutter'},
};

/** `MurmurState.transitionDuration`: how long a state change takes to cross. */
export const TRANSITION = 0.6;
/** `MurmurView.stillTime`: the time and state age of the one frame Reduce Motion draws. */
export const STILL_TIME = 4.0;
/** `MurmurSignals`: the voice's lift on the light, and the envelope's rise and fall. */
const LEVEL_GLOW_LIFT = 0.35;
const ATTACK = 0.05;
const RELEASE = 0.25;

/** `MurmurClock.ease`: smoothstep over the transition, so the crossfade has no corners. */
export function ease(elapsed) {
    const t = clamp(elapsed / TRANSITION, 0, 1);
    return t * t * (3 - 2 * t);
}

/** `mh_state`: what the state's own age adds. */
export function stateTerms(index, tau) {
    const o = {complete: 0, sweep: 0, settled: 0, drive: 0};
    const t = Math.max(tau, 0);
    if (index === 4) {
        const a = clamp(t / 1.2, 0, 1);
        o.complete = smoothstep(0, 0.30, a) * (1 - smoothstep(0.36, 1.0, a));
        o.settled = smoothstep(0.30, 1.05, a);
        o.sweep = smoothstep(0, 1, clamp(t / 0.95, 0, 1));
    } else if (index === 3) {
        o.drive = smoothstep(0, 0.55, t);
    }
    return o;
}

/** `mh_drift`: a phase that never ticks — an eased angle, strictly forward. */
export function drift(t, rate, wobble, lane) {
    const k = clamp(wobble, 0, 0.72);
    const w2 = 0.137 + 0.0413 * lane;
    return rate * t + (k * rate / w2) * Math.sin(w2 * t + lane * 1.71);
}

// MARK: - The entries (`MurmurEntry`)

/** Multiplier on the tempo: wake overshoots and decays in. */
export function speedBoost(entry, tau) {
    return entry === 'wake' && tau > 0 && tau < 2.5 ? 1 + 0.6 * Math.exp(-tau / 0.4) : 1;
}

/** Multiplier on the light: swell rises and settles, the arrival breath. */
export function glowBoost(entry, tau) {
    if (entry !== 'swell' || !(tau > 0 && tau < 1.5))
        return 1;
    const x = tau / 0.4;
    const shape = x ** 2 * Math.exp(2 * (1 - x));
    const taper = 1 - smoothstep(0, 1, (tau - 1.1) / 0.4);
    return 1 + 0.35 * shape * taper;
}

/** Offset on the phase, in seconds at the state's tempo: stutter's two catches of the clock. */
export function phaseOffset(entry, tau) {
    if (entry !== 'stutter' || !(tau > 0 && tau < 0.5))
        return 0;
    const arch = (start, width) => {
        const u = (tau - start) / width;
        return u > 0 && u < 1 ? Math.sin(Math.PI * u) : 0;
    };
    return -(0.030 * arch(0.05, 0.20) + 0.018 * arch(0.28, 0.16));
}

// MARK: - The clock (`MurmurView.frame`, `MurmurClock`, `MurmurSignalEnvelope`)

/**
 * One capsule's clock. Make a new one when the capsule appears: the phase
 * starts at zero there, as `MurmurView`'s birth does. Each frame adds
 * dt × tempo — the crossfading speed times the entry's overshoot — so the
 * shader's `time * speed` never jumps when the tempo changes underneath it.
 */
export class MurmurClock {
    constructor() {
        this.state = null;
        this.previous = null;
        this.changedAt = 0;
        this.phase = 0;
        this.last = null;
        this.level = 0;
        this.levelAt = null;
    }

    /** The tempo `tau` seconds into the current segment. */
    tempo(tau) {
        const from = SEEDS[this.previous], to = SEEDS[this.state];
        return mix(from.speed, to.speed, ease(tau)) * speedBoost(to.entry, tau);
    }

    _advance(now) {
        if (this.last !== null && now > this.last) {
            // The tempo at the step's middle: the integral is exact for a steady tempo.
            const mid = Math.max((this.last + now) / 2 - this.changedAt, 0);
            this.phase += (now - this.last) * this.tempo(mid);
        }
        this.last = this.last === null ? now : Math.max(this.last, now);
    }

    /**
     * The live level, smoothed: a fast rise and a slow fall, written against dt
     * so it has the same shape at any frame rate. The first frame snaps.
     */
    _envelope(target, now) {
        const goal = clamp(Number(target) || 0, 0, 1);
        if (this.levelAt === null) {
            this.levelAt = now;
            this.level = goal;
            return goal;
        }
        if (now === this.levelAt)
            return this.level;
        const dt = clamp(now - this.levelAt, 0, 0.25);
        this.levelAt = now;
        const k = goal > this.level ? ATTACK : RELEASE;
        this.level += (goal - this.level) * (1 - Math.exp(-dt / k));
        return this.level;
    }

    /**
     * What the orb draws at `now` (seconds) showing `state`, with the voice at
     * `level`: `{phase, tau, glow, depth, hueShift, level}`. With `reduced`, the
     * one still frame: four seconds in, the design arrived, no entry, the raw level.
     */
    frame(state, now, level = 0, {reduced = false} = {}) {
        if (!SEEDS[state])
            state = 'idle';
        if (reduced) {
            const s = SEEDS[state];
            const raw = clamp(Number(level) || 0, 0, 1);
            return {
                phase: STILL_TIME * s.speed, tau: STILL_TIME,
                glow: s.glow * (1 + LEVEL_GLOW_LIFT * raw), depth: s.depth, hueShift: s.hueShift, level: raw,
            };
        }
        if (this.state === null) {
            // Nothing to cross from: the design starts arrived, and the entry still runs.
            this.state = this.previous = state;
            this.changedAt = now;
            this.last = now;
        } else {
            this._advance(now);
            if (state !== this.state) {
                this.previous = this.state;
                this.state = state;
                this.changedAt = now;
            }
        }
        const tau = Math.max(now - this.changedAt, 0);
        const from = SEEDS[this.previous], to = SEEDS[this.state];
        const e = ease(tau);
        const live = this._envelope(level, now);
        return {
            // The stutter's lag scales with the state's own tempo.
            phase: Math.max(this.phase + phaseOffset(to.entry, tau) * to.speed, 0),
            tau,
            glow: mix(from.glow, to.glow, e) * glowBoost(to.entry, tau) * (1 + LEVEL_GLOW_LIFT * live),
            depth: mix(from.depth, to.depth, e),
            hueShift: mix(from.hueShift, to.hueShift, e),
            level: live,
        };
    }
}

// MARK: - Colour (`mh_palette`, `mh_shade`, `mh_lit`, `mh_present`)

const toLinear = c => {
    c = Math.max(c, 0);
    return c > 0.04045 ? ((c + 0.055) / 1.055) ** 2.4 : c / 12.92;
};
const toSrgb = c => {
    c = Math.max(c, 0);
    return c > 0.0031308 ? 1.055 * c ** (1 / 2.4) - 0.055 : c * 12.92;
};

function oklab([r, g, b]) {
    const l = Math.cbrt(Math.max(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b, 0));
    const m = Math.cbrt(Math.max(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b, 0));
    const s = Math.cbrt(Math.max(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b, 0));
    return [
        0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
        1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
        0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
    ];
}

function linearOf([L, a, b]) {
    const l = (L + 0.3963377774 * a + 0.2158037573 * b) ** 3;
    const m = (L - 0.1055613458 * a - 0.0638541728 * b) ** 3;
    const s = (L - 0.0894841775 * a - 1.2914855480 * b) ** 3;
    return [
        4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
        -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
        -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
    ];
}

const lch = (L, C, h) => [L, C * Math.cos(h), C * Math.sin(h)];
const mix3 = (a, b, t) => [mix(a[0], b[0], t), mix(a[1], b[1], t), mix(a[2], b[2], t)];

/**
 * `mh_palette`'s ink rail: four OKLAB stops from the tone — the ink, a deep
 * shadow that keeps the hue, the tone, and a pale hot end a little warmer.
 * `depth` opens the range; `hueShift` walks the family (error: −0.35 rad).
 * The capsule's ink is dark, so the paper rail (`mh_paper` = 0) never mixes in.
 */
export function palette(ink, tone, tone2, hueShift = 0, depth = 1) {
    const i = oklab(ink.map(toLinear));
    const t1 = oklab(tone.map(toLinear));
    const t2 = oklab(tone2.map(toLinear));
    const L = t1[0], C = Math.hypot(t1[1], t1[2]);
    const h0 = Math.atan2(t1[2], t1[1]);
    const h = h0 + hueShift;
    const d = clamp(depth, 0.30, 2.00);
    // The second anchor, as a difference from the first, the short way round.
    let dh = Math.atan2(t2[2], t2[1]) - h0;
    dh -= TAU * Math.floor(dh / TAU + 0.5);
    return {
        s0: i,
        s1: lch(mix(i[0], L, 0.30 / d), C * (0.52 + 0.10 * d), h - 0.35),
        s2: lch(L, C, h),
        s3: lch(Math.min(L * (1.20 + 0.12 * d), 0.93), C * 0.55, h + 0.10),
        duo: smoothstep(0.004, 0.035, Math.hypot(t2[0] - t1[0], t2[1] - t1[1], t2[2] - t1[2])),
        dHue: dh,
        dC: Math.hypot(t2[1], t2[2]) / Math.max(C, 1e-4),
        dL: t2[0] / Math.max(L, 1e-4),
    };
}

/** `mh_shade`: walk the rail to `t`, the hue rotated `hue` along the spread. Linear light. */
export function shade(p, t, hue = 0) {
    t = clamp(t, 0, 1);
    let lab;
    if (t < 0.40)
        lab = mix3(p.s0, p.s1, smoothstep(0, 1, t * 2.5));
    else if (t < 0.78)
        lab = mix3(p.s1, p.s2, smoothstep(0, 1, (t - 0.40) / 0.38));
    else
        lab = mix3(p.s2, p.s3, smoothstep(0, 1, (t - 0.78) / 0.22));
    const a = hue / MH_SPREAD;
    const pos = Math.max(a, 0), neg = Math.max(-a, 0);
    const rot = -neg * MH_SPREAD + pos * mix(MH_SPREAD, p.dHue, p.duo);
    const w = Math.min(pos, 1) * p.duo;
    const cS = 1 + w * (p.dC - 1), lS = 1 + w * (p.dL - 1);
    const ch = Math.cos(rot), sh = Math.sin(rot);
    return linearOf([lab[0] * lS, (lab[1] * ch - lab[2] * sh) * cS, (lab[1] * sh + lab[2] * ch) * cS]);
}

const knee = (x, k) => x < k ? x : k + (1 - k) * (1 - Math.exp(-(x - k) / Math.max(1 - k, 1e-3)));

/** `mh_tier`: ink ground, tone body, hot peaks — the last fifth of the energy spent on the top of the rail. */
function tier(e) {
    const x = clamp(e, 0, 1), K = 0.78;
    return mix((x / K) * 0.72, 0.72 + ((x - K) / (1 - K)) * 0.28, smoothstep(K - 0.10, K + 0.10, x));
}

/**
 * The one place energy becomes light (`mh_lit` then `mh_present`'s knee):
 * the sRGB colour, 0–1, of `e` at `glow` with the hue turned `hue`. The hot
 * end carries the emissive lift, 1 + 0.34·G over the top of the rail.
 */
export function lit(p, e, glow, hue = 0) {
    const G = Math.max(glow, 0);
    const en = clamp(knee(Math.max(e, 0) * (0.35 + 0.65 * G), 0.92), 0, 1);
    const t = clamp(tier(en), 0, 1);
    const lift = 1 + 0.34 * G * smoothstep(0.72, 1, t);
    return shade(p, t, hue).map(c => clamp(toSrgb(knee(c * lift, 0.90)), 0, 1));
}

/** `mh_key`: the key light, drifting slowly so the catchlight is never pinned. */
export function keyLight(t) {
    const dr = t * 0.21;
    const v = [-0.52 + 0.055 * Math.sin(dr), -0.60 + 0.045 * Math.cos(dr * 0.83), 0.61];
    const n = Math.hypot(...v);
    return v.map(c => c / n);
}

/** Where the catchlight sits, in body radii from the centre: the half vector's x and y (about −0.29, −0.33). */
export function catchlight(t) {
    const k = keyLight(t);
    const H = [k[0], k[1], k[2] + 1];
    const n = Math.hypot(...H);
    return {x: H[0] / n, y: H[1] / n};
}

// MARK: - Drawing

/** The body's own light: the medium's floor, a whisper of energy on the rail. */
const BODY_FLOOR = 0.06;
/** The interior wash's opacity per unit of `hintAmt`, at its centre. */
const HINT_ALPHA = 1.3;
/** The band's flank energy, as a share of its centre's. */
const FLANK = 0.6;
/**
 * What the glint stands on beyond its own lobe: the body, the hint and the rim
 * under it. Fitted against the shader's peak (teal goes near-white, the error's
 * red stays red at 226,59,117).
 */
const GLINT_LIFT = 0.1;

/**
 * `mh_surface`'s rim weight at the silhouette, where the normal is (cos φ, sin φ, 0):
 * `wrap` (brighter away from the key, toward (0.42, 0.50)) times `envRim` (the sky
 * above lifts the top edge). Screen y runs down, as the shader's does. Peaks at 1.
 */
export function rimWeight(phi) {
    const nx = Math.cos(phi), ny = Math.sin(phi);
    const d = Math.hypot(0.42, 0.50);
    const wrap = 0.55 + 0.45 * clamp((nx * 0.42 + ny * 0.50) / d, 0, 1);
    const envRim = mix(0.86, 1.14, 0.5 - 0.5 * ny);
    return wrap * envRim / RIM_PEAK;
}
const RIM_PEAK = (() => {
    let m = 0;
    for (let k = 0; k < 720; k++) {
        const phi = k * TAU / 720, nx = Math.cos(phi), ny = Math.sin(phi);
        const wrap = 0.55 + 0.45 * clamp((nx * 0.42 + ny * 0.50) / Math.hypot(0.42, 0.50), 0, 1);
        m = Math.max(m, wrap * mix(0.86, 1.14, 0.5 - 0.5 * ny));
    }
    return m;
})();

/** Cairo's operators, by number. */
const OPERATOR_OVER = 2;
const OPERATOR_ADD = 12;

/**
 * Draws `fn`'s abutting segments as one layer: added together in a group of their
 * own, where the antialiased edges two neighbours share sum to full coverage, and
 * the group laid over what is below. Drawn over each other, every shared edge
 * would leave a faint seam, and the band would read as hatched.
 */
function additive(cr, fn) {
    if (![cr.pushGroup, cr.setOperator, cr.popGroupToSource, cr.paint].every(f => typeof f === 'function')) {
        fn();
        return;
    }
    cr.pushGroup();
    cr.setOperator(OPERATOR_ADD);
    fn();
    cr.popGroupToSource();
    cr.setOperator(OPERATOR_OVER);
    cr.paint();
}

function disc(cr, cx, cy, r) {
    cr.newPath();
    cr.moveTo(cx + r, cy);
    cr.arc(cx, cy, r, 0, TAU);
    cr.closePath();
    cr.fill();
}

/**
 * Draws the orb in a `size` square with its top left at (x, y).
 *
 * @param g the Gfx
 * @param params
 *   state     'idle' | 'listening' | 'thinking' | 'responding' | 'success' | 'error' (the state being entered)
 *   tone      [r, g, b] 0–1: the light's colour
 *   tone2     [r, g, b]: the second anchor (`mh_palette`'s duotone)
 *   level     the voice, 0–1 (smoothed, from `MurmurClock.frame`)
 *   phase     the integrated phase, the shader's `time * speed` (from `MurmurClock.frame`)
 *   tau       seconds since the state changed
 *   glow, depth, hueShift   the crossfaded design (from `MurmurClock.frame`)
 *   t         without `phase`: seconds on a clock, at the state's own tempo
 *   ink       [r, g, b]: the glass (default Murmur's `ORB_INK`)
 */
export function drawOrb(g, x, y, size, {state, tone, tone2, level = 0, phase, t = 0, tau = 99, glow, depth, hueShift, ink = ORB_INK}) {
    const spec = SEEDS[state] ?? SEEDS.idle;
    const st = stateTerms(spec.index, tau);
    const cx = x + size / 2, cy = y + size / 2;
    const R = BODY * size;
    level = clamp(level, 0, 1);
    const voice = Math.pow(level, 0.65) * (spec.index === 1 ? 1 : 0.55);
    const time = phase ?? t * spec.speed;
    glow ??= spec.glow * glowBoost(spec.entry, tau) * (1 + LEVEL_GLOW_LIFT * level);
    const pal = palette(ink, tone, tone2 ?? tone, hueShift ?? spec.hueShift, depth ?? spec.depth);
    const a = g.alpha;
    const cr = g.cr;

    cr.save();
    // The ink the shader runs on: the whole frame's circle, opaque.
    cr.setSourceRGBA(ink[0], ink[1], ink[2], a);
    disc(cr, cx, cy, size / 2);

    // Everything else is light inside the glass: none of it leaves the body.
    cr.newPath();
    cr.moveTo(cx + R, cy);
    cr.arc(cx, cy, R, 0, TAU);
    cr.closePath();
    cr.clip();

    // The body: near-black glass on the rail, not grey — the medium's floor
    // (`mh_medium` × 0.030) is a little energy, so the ink already wears the tone.
    cr.setSourceRGBA(...lit(pal, BODY_FLOOR, glow), a);
    disc(cr, cx, cy, R);

    // The arc. Its angle drifts, easing, never stalling; success drives one extra lap.
    const wobble = mix(0.62, 0.14, st.drive);
    const rate = (0.34 + 0.40 * LIMN.travel) * (1 + 0.30 * voice) * (1 + 1.05 * st.drive);
    const phi0 = drift(time, rate, wobble, 1.0) + st.sweep * TAU;

    // The interior hint (`hintAmt`, `interior`): the volume glows faintly where
    // the arc's light entered, strongest under the arc and dying toward the middle.
    const hintAmt = 0.22 + 0.38 * LIMN.hint;
    const wash = lit(pal, 0.5, glow), washEdge = lit(pal, 0.25, glow);
    const hx = cx + Math.cos(phi0) * R * 0.6, hy = cy + Math.sin(phi0) * R * 0.6;
    const washAlpha = clamp(HINT_ALPHA * hintAmt * (1 + 0.9 * voice) * (1 + 0.9 * st.complete), 0, 1) * a;
    cr.setSourceRadial(hx, hy, 0, hx, hy, R * 1.1, [
        [0, ...wash, washAlpha],
        [0.35, ...washEdge, washAlpha * 0.6],
        [1, ...washEdge, 0],
    ]);
    disc(cr, cx, cy, R);

    // The edge that closes the sphere all the way round (`mh_surface`'s rim, 0.30):
    // brighter on the side away from the key (`wrap`) and off the sky above (`envRim`).
    const RIM_SEGMENTS = 72;
    const rimLap = TAU / RIM_SEGMENTS;
    const rimColour = lit(pal, 0.30, glow);
    additive(cr, () => {
        for (let k = 0; k < RIM_SEGMENTS; k++) {
            const phi = k * rimLap;
            g.strokeArc(cx, cy, R - 0.6, phi - rimLap / 2, phi + rimLap / 2, [...rimColour, 0.9 * rimWeight(phi)], 1.1, false);
        }
    });

    // Head and tail are von Mises bumps — periodic by construction, so the comma has no seam.
    const kHead = 9.0 / (1 + 0.60 * voice);
    const kTail = 1.6 / (1 + 0.35 * voice + 0.30 * st.drive);
    const offT = -1.05 - 0.30 * st.drive;
    const bandWidth = Math.min((0.070 + 0.055 * LIMN.width) * (1 + 0.55 * voice), 0.30) * R;
    const radius = R * 0.965;
    const SEGMENTS = 144;
    const lap = TAU / SEGMENTS;
    const peak = (1.70 + 1.15 * voice) * (1 + 1.6 * st.complete) * (1 + 0.30 * st.settled);
    // The band's Fresnel at 0.965 of the body: (0.30 + 0.70 · fres^1.6), fres = 1 − √(1 − 0.965²).
    const rimFresnel = 0.30 + 0.70 * Math.pow(1 - Math.sqrt(1 - 0.965 * 0.965), 1.6);
    const segments = [];
    for (let k = 0; k < SEGMENTS; k++) {
        const phi = k * lap;
        let aw = phi - phi0;
        aw -= TAU * Math.floor(aw / TAU + 0.5);
        const headLobe = Math.exp(kHead * (Math.cos(aw) - 1));
        const tailLobe = Math.exp(kTail * (Math.cos(aw - offT) - 1));
        const arc = headLobe + 0.52 * tailLobe;
        // Success closes the circle, once, for a breath: the one frame a full even ring is right.
        const energy = arc * peak + st.complete * 1.20;
        const alpha = 1 - Math.exp(-1.15 * energy * glow * 0.85);
        if (alpha < 0.01)
            continue;
        // The tail's own share of the light turns its hue down the family, as old light cools.
        const tailShare = (0.52 * tailLobe) / Math.max(headLobe + 0.52 * tailLobe, 1e-4);
        const e = rimFresnel * arc * peak + st.complete * 1.20, hue = -tailShare * LIMN.spread * MH_SPREAD;
        // The flank of the Gaussian band carries less energy, so it sits lower on the
        // rail — saturated tone rather than the head's pale colour faded toward grey.
        segments.push({phi, alpha, core: lit(pal, e, glow, hue), flank: lit(pal, e * FLANK, glow, hue)});
    }
    // Two passes of the Gaussian band, a soft one 2·bw across and a core: each
    // segment spans exactly its own lap, so neighbours meet and never overlap.
    for (let pass = 0; pass < 2; pass++) {
        const width = pass === 0 ? bandWidth * 2 : bandWidth * 1.2;
        additive(cr, () => {
            for (const {phi, alpha, core, flank} of segments)
                g.strokeArc(cx, cy, radius, phi - lap / 2, phi + lap / 2, pass === 0 ? [...flank, alpha * 0.8] : [...core, alpha], width, false);
        });
    }

    // The one catchlight (`mh_surface`'s two lobes) where the half vector meets the
    // sphere: a broad faint sheen, and a tight glint about a tenth of the body
    // across that the rail takes to its near-white hot end.
    const specK = 0.78 + 0.35 * voice;
    const key = catchlight(time);
    const gx = cx + key.x * R, gy = cy + key.y * R;
    const sheen = lit(pal, specK * 0.5, glow);
    cr.setSourceRadial(gx, gy, 0, gx, gy, R * 0.55, [
        [0, ...sheen, 0.10 * specK * a],
        [1, ...sheen, 0],
    ]);
    disc(cr, gx, gy, R * 0.55);
    const glint = lit(pal, specK * 1.09 + GLINT_LIFT, glow);
    const glintR = R * 0.1;
    cr.setSourceRadial(gx, gy, 0, gx, gy, glintR, [
        [0, ...glint, a],
        [0.6, ...glint, 0.75 * a],
        [1, ...glint, 0],
    ]);
    disc(cr, gx, gy, glintR);
    cr.restore();
}
