// Run with: node --test linux/js/test/*.test.js
// The Settings window's motion against the Swift's (`SettingsMotion`,
// `ModulesSection.expand`, the hovers): SwiftUI's springs as `linear()`
// easings, its curves as cubic Béziers, and no transition the Swift lacks.
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';

import {CHANGE, HOVER, REDUCED, SPRING, UNFOLD, springEasing, springProgress, springSettle} from '../settings/motion.js';

const source = name => readFileSync(new URL(`../settings/${name}`, import.meta.url), 'utf8');

/** A `linear()` easing read back: its stops, an input between 0 and 1, the output at it. */
function linear(easing) {
    const stops = easing.slice('linear('.length, -1).split(', ').map(stop => stop.split(' ').map(parseFloat));
    const points = stops.map(([value, at], i) => [value, at === undefined ? (i === 0 ? 0 : 100) : at]);
    return x => {
        const p = x * 100;
        for (let i = 1; i < points.length; i++) {
            const [v0, x0] = points[i - 1], [v1, x1] = points[i];
            if (p <= x1)
                return v0 + (v1 - v0) * (p - x0) / (x1 - x0);
        }
        return points.at(-1)[0];
    };
}

/** The oscillator SwiftUI's spring is, stepped through (RK4): unit mass, stiffness (2π/response)², damping 4π·dampingFraction/response. */
function oscillator(response, damping, until, dt = 1e-5) {
    const k = (2 * Math.PI / response) ** 2, c = 4 * Math.PI * damping / response;
    const f = (x, v) => [v, -k * (x - 1) - c * v];
    let x = 0, v = 0;
    const out = new Map();
    for (let i = 0, n = Math.round(until / dt); i <= n; i++) {
        if (i % 1000 === 0)
            out.set(Math.round(i * dt * 1000), x);
        const [a1, b1] = f(x, v), [a2, b2] = f(x + a1 * dt / 2, v + b1 * dt / 2);
        const [a3, b3] = f(x + a2 * dt / 2, v + b2 * dt / 2), [a4, b4] = f(x + a3 * dt, v + b3 * dt);
        x += (a1 + 2 * a2 + 2 * a3 + a4) * dt / 6;
        v += (b1 + 2 * b2 + 2 * b3 + b4) * dt / 6;
    }
    return out;
}

test('the spring is the damped oscillator SwiftUI\'s `.spring(response:dampingFraction:)` is', () => {
    for (const [response, damping] of [[0.3, 0.75], [0.32, 0.9]]) {
        for (const [ms, x] of oscillator(response, damping, 0.6))
            assert.ok(Math.abs(springProgress(response, damping, ms / 1000) - x) < 1e-6, `${response}/${damping} at ${ms} ms`);
    }
});

test('the switches\' and the sidebar\'s spring overshoots by 2.8%, a section change\'s by 0.15%, as the formulas say', () => {
    const peak = (response, damping) => {
        let most = 0;
        for (let t = 0; t < 1; t += 0.0001)
            most = Math.max(most, springProgress(response, damping, t));
        return most - 1;
    };
    // e^(−πζ/√(1−ζ²))
    const overshoot = damping => Math.exp(-Math.PI * damping / Math.sqrt(1 - damping * damping));
    assert.ok(Math.abs(peak(0.3, 0.75) - overshoot(0.75)) < 1e-5);
    assert.ok(Math.abs(peak(0.32, 0.9) - overshoot(0.9)) < 1e-5);
    assert.equal(+(overshoot(0.75) * 100).toFixed(2), 2.84);
    assert.equal(+(overshoot(0.9) * 100).toFixed(2), 0.15);
});

test('each spring runs until it has settled within a thousandth, and no longer', () => {
    for (const [response, damping, motion] of [[0.3, 0.75, SPRING], [0.32, 0.9, CHANGE]]) {
        const settle = springSettle(response, damping);
        assert.equal(motion.duration, Math.round(settle * 1000));
        for (let t = settle; t < 3; t += 0.001)
            assert.ok(Math.abs(1 - springProgress(response, damping, t)) < 0.001, `${response}/${damping} at ${t}`);
        assert.ok(Math.abs(1 - springProgress(response, damping, settle - 0.002)) >= 0.001 - 1e-4);
    }
    assert.equal(SPRING.duration, 383);
    assert.equal(CHANGE.duration, 428);
});

test('the sampled easings follow the springs, the overshoot\'s peak kept, with 40 to 60 stops', () => {
    for (const [response, damping, motion] of [[0.3, 0.75, SPRING], [0.32, 0.9, CHANGE]]) {
        const ease = linear(motion.easing);
        let most = 0;
        for (let ms = 0; ms <= motion.duration; ms += 0.25) {
            most = Math.max(most, ease(ms / motion.duration));
            assert.ok(Math.abs(ease(ms / motion.duration) - springProgress(response, damping, ms / 1000)) < 0.0012,
                `${response}/${damping} at ${ms} ms`);
        }
        let peak = 0;
        for (let t = 0; t < 1; t += 0.0001)
            peak = Math.max(peak, springProgress(response, damping, t));
        assert.ok(Math.abs(most - peak) < 0.0003, `${response}/${damping}: peak ${most} against ${peak}`);
        assert.ok(motion.points.length >= 40 && motion.points.length <= 60, `${motion.points.length} stops`);
        assert.equal(ease(0), 0);
        assert.equal(ease(1), 1);
    }
    // The same spring asked again is the same easing.
    assert.equal(springEasing(0.3, 0.75).easing, SPRING.easing);
});

test('the curves that are not springs are the Swift\'s own Béziers', () => {
    // `.easeInOut(duration: 0.15)`, Reduce Motion's.
    assert.deepEqual(REDUCED, {duration: 150, easing: 'cubic-bezier(0.42, 0, 0.58, 1)'});
    // `.timingCurve(0.23, 1, 0.32, 1, duration: 0.2)`, a Module card opening.
    assert.deepEqual(UNFOLD, {duration: 200, easing: 'cubic-bezier(0.23, 1, 0.32, 1)'});
    // `.easeOut(duration: 0.12)`, a hover; CSS's `ease-out` is the same curve.
    assert.deepEqual(HOVER, {duration: 120, easing: 'cubic-bezier(0, 0, 0.58, 1)'});
});

test('the style sheet animates nothing but the hovers the Swift eases, and keeps nothing running on its own', () => {
    const css = source('settings.css');
    assert.doesNotMatch(css, /@keyframes|(^|[\s;{])animation\s*:/m);
    const transitions = [...css.matchAll(/(^|[\s;{])transition\s*:\s*([^;]+);/gm)].map(m => m[2].trim());
    // `.side-item`, `SettingsRow` and onboarding's `ModuleCard` row: `.animation(.easeOut(duration: 0.12), value: hovering)`.
    assert.deepEqual(transitions, ['none !important', 'background-color 0.12s ease-out', 'background-color 0.12s ease-out', 'background-color 0.12s ease-out']);
});

test('the page plays its motions on the Swift\'s curves: the switch and the sidebar on the spring, a change on its own', () => {
    const page = source('page.js'), dom = source('dom.js');
    assert.match(dom, /export const springMotion = \(\) => \(reduced\(\) \? REDUCED : SPRING\);/);
    assert.match(page, /const changeMotion = \(\) => \(reduced\(\) \? REDUCED : CHANGE\);/);
    // Under Reduce Motion a Module card is simply open (`withAnimation(reduced ? nil : …)`).
    assert.match(page, /unfold\(before\) \{\n\s+if \(reduced\(\)\)\n\s+return;/);
    // Onboarding's Teleprompter shortcuts come with no animation of their own: nothing drives them in the Swift.
    assert.doesNotMatch(page, /'data-appear': 'shortcuts'/);
});
