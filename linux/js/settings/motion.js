// The Swift's motion (`SettingsMotion`, `ModulesSection.expand`, the hovers),
// as the page plays it: SwiftUI's springs sampled into CSS `linear()` easings,
// its timing curves as the same cubic Béziers.

/**
 * How far a SwiftUI `.spring(response:dampingFraction:)` has gone at `t`
 * seconds: a damped oscillator of unit mass, stiffness (2π/response)² and
 * damping 4π·dampingFraction/response, let go at rest. 0 at the start, 1 at
 * rest; past 1 while it overshoots.
 */
export function springProgress(response, damping, t) {
    if (t <= 0)
        return 0;
    const w0 = 2 * Math.PI / response;
    if (damping >= 1)
        return 1 - Math.exp(-w0 * t) * (1 + w0 * t);
    const decay = damping * w0;
    const wd = w0 * Math.sqrt(1 - damping * damping);
    return 1 - Math.exp(-decay * t) * (Math.cos(wd * t) + decay / wd * Math.sin(wd * t));
}

/** How long, in seconds, before the spring stays within `epsilon` of rest for good. */
export function springSettle(response, damping, epsilon = 0.001) {
    const step = 0.0005;
    let last = 0;
    for (let t = 0; t < 10; t += step) {
        if (Math.abs(1 - springProgress(response, damping, t)) >= epsilon)
            last = t;
    }
    return Math.ceil((last + step) * 1000) / 1000;
}

/**
 * A spring as a CSS easing over its settle time: `linear()` stops placed where
 * a straight line between them stays within `tolerance` of the spring, so the
 * overshoot's peak is kept, not cut between two evenly spaced stops.
 */
export function springEasing(response, damping, {epsilon = 0.001, tolerance = 0.0002} = {}) {
    const duration = springSettle(response, damping, epsilon);
    const n = 2000;
    const samples = Float64Array.from({length: n + 1}, (_, i) => springProgress(response, damping, duration * i / n));
    const at = i => samples[i];
    const stops = [0];
    let from = 0;
    while (from < n) {
        // The longest straight stretch from `from` that keeps to the curve.
        let to = from + 1;
        for (let end = from + 2; end <= n; end++) {
            let fits = true;
            for (let i = from + 1; i < end && fits; i++) {
                const line = at(from) + (at(end) - at(from)) * (i - from) / (end - from);
                fits = Math.abs(line - at(i)) <= tolerance;
            }
            if (!fits)
                break;
            to = end;
        }
        stops.push(to);
        from = to;
    }
    const points = stops.map(i => (i === n ? [1, 1] : [at(i), i / n]));
    const easing = `linear(${points.map(([v, x], k) =>
        (k === 0 ? '0' : k === points.length - 1 ? '1' : `${+v.toFixed(4)} ${+(x * 100).toFixed(2)}%`)).join(', ')})`;
    return {duration: Math.round(duration * 1000), easing, points};
}

/** Switches and the sidebar's highlight: `SettingsMotion.spring`, `spring(response: 0.3, dampingFraction: 0.75)`. */
export const SPRING = springEasing(0.3, 0.75);
/** Changing section or step: `SettingsMotion.change`, `spring(response: 0.32, dampingFraction: 0.9)`. */
export const CHANGE = springEasing(0.32, 0.9);
/** Either of them under Reduce Motion: `.easeInOut(duration: 0.15)`. */
export const REDUCED = {duration: 150, easing: 'cubic-bezier(0.42, 0, 0.58, 1)'};
/** A Module card opening (`ModulesSection.expand`): `.timingCurve(0.23, 1, 0.32, 1, duration: 0.2)`; none under Reduce Motion. */
export const UNFOLD = {duration: 200, easing: 'cubic-bezier(0.23, 1, 0.32, 1)'};
/** A row or a sidebar line lit under the pointer: `.easeOut(duration: 0.12)`. */
export const HOVER = {duration: 120, easing: 'cubic-bezier(0, 0, 0.58, 1)'};
