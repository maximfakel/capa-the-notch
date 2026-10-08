// Run with: node --test linux/js/test
import assert from 'node:assert/strict';
import test from 'node:test';

import {CairoCanvas} from '../cairo-canvas.js';
import {GREEN, RED, YELLOW, chipFor, paintGauge, resetText, stripPairs} from '../gauge.js';
import {Geometry, SPRING_SETTLE_SECONDS, addOutline, spring} from '../geometry.js';
import {drawMark} from '../marks.js';

/** A drawing context that remembers what it was asked. */
function recorder() {
    const calls = [];
    return new Proxy({calls}, {
        get: (target, name) => name === 'calls' ? calls : (...args) => { calls.push([name, ...args]); },
    });
}

const window = (id, remaining, extra = {}) => ({
    id, label: id, remainingPercentage: remaining, remainingFraction: remaining / 100,
    pace: remaining >= 60 ? 'sustainable' : remaining >= 10 ? 'tightening' : 'unsustainable',
    resetKind: 'unknown', resetsAt: null, resetIn: null, ...extra,
});

const view = (provider, extra = {}) => ({
    provider, name: provider, state: 'fresh', guidance: null, reasonRepeatsTheChip: false,
    needsAPersonFirst: false, switchedOff: false, headline: null, windows: [], ...extra,
});

test('geometry: 210 open over a 38-point bar, 370 closed, 560 open', () => {
    const g = new Geometry(38);
    assert.equal(g.openHeight, 210);
    assert.equal(g.compactWidth(), 370);
    assert.equal(g.surfaceWidth(), 560);
});

test('geometry: a notch wider than the drawings still leaves a figure each side', () => {
    const g = new Geometry(38, 300);
    assert.equal(g.compactWidth(), 485);
    assert.ok(g.surfaceWidth() >= g.compactWidth());
});

test('spring: starts at rest, gives a little on opening, never on closing, settles', () => {
    assert.ok(Math.abs(spring(0, true)) < 1e-9);
    const opening = Array.from({length: 100}, (_, i) => spring(i * 0.01, true));
    assert.ok(Math.max(...opening) > 1, 'opening overshoots');
    assert.ok(Math.max(...opening) < 1.1, 'but only a little');
    const closing = Array.from({length: 100}, (_, i) => spring(i * 0.01, false));
    assert.ok(Math.max(...closing) <= 1, 'closing does not');
    assert.ok(Math.abs(spring(SPRING_SETTLE_SECONDS, true) - 1) < 0.01);
    assert.ok(Math.abs(spring(SPRING_SETTLE_SECONDS, false) - 1) < 0.01);
});

test('outline: one closed path, shoulders outside the shape, nothing for an empty one', () => {
    const cr = recorder();
    addOutline(cr, 20, 0, 370, 38, 22);
    const names = cr.calls.map(c => c[0]);
    assert.equal(names[0], 'moveTo');
    assert.deepEqual(cr.calls[0].slice(1), [0, 0], 'starts one shoulder (20) left of the shape');
    assert.equal(names.at(-1), 'closePath');
    assert.equal(names.filter(n => n === 'curveTo').length, 4);

    const empty = recorder();
    addOutline(empty, 0, 0, 0, 38, 22);
    assert.equal(empty.calls.length, 0);
});

test('outline: a strip too short for a shoulder and a corner gives the corner way', () => {
    const cr = recorder();
    addOutline(cr, 20, 0, 100, 10, 22);
    const bottomLeft = cr.calls.find(c => c[0] === 'lineTo');
    assert.equal(bottomLeft[2], 10 - 0, 'the side runs the whole short height: corner is zero');
});

test('strip: two Providers show a headline each, one shows its two windows', () => {
    const a = view('codex', {headline: 'w', windows: [window('x', 80), window('w', 30)]});
    const b = view('claudeCode', {headline: 'y', windows: [window('y', 55)]});
    const two = stripPairs([a, b]);
    assert.deepEqual(two.map(([v, w]) => [v.provider, w.id]), [['codex', 'w'], ['claudeCode', 'y']]);
    const one = stripPairs([a]);
    assert.deepEqual(one.map(([, w]) => w.id), ['x', 'w']);
    assert.deepEqual(stripPairs([]), []);
});

test('chip: what a person must do first says No data; a used-up month says so; states have colours', () => {
    assert.deepEqual(chipFor(view('codex', {state: 'disconnected', needsAPersonFirst: true})), {text: 'No data', color: RED});
    assert.equal(chipFor(view('openCode', {reasonRepeatsTheChip: true, guidance: 'Monthly limit reached'})).text, 'Month used up');
    assert.deepEqual(chipFor(view('codex', {state: 'fresh'})), {text: 'Fresh', color: GREEN});
    assert.deepEqual(chipFor(view('codex', {state: 'stale'})), {text: 'Stale', color: YELLOW});
    assert.equal(chipFor(view('codex', {state: 'disconnected'})).text, '—');
});

test('reset: a time of day, a countdown, or a dash', () => {
    assert.equal(resetText(window('w', 50, {resetKind: 'in', resetIn: '3d'})), '3d');
    assert.equal(resetText(window('w', 50)), '—');
    assert.match(resetText(window('w', 50, {resetKind: 'at', resetsAt: 1_700_000_000})), /\d/);
});

test('gauge: a track and an arc in the pace colour; used up is a red track and no arc', () => {
    const cr = recorder();
    paintGauge(cr, 88, 88, window('w', 50));
    const strokes = cr.calls.filter(c => c[0] === 'stroke').length;
    assert.equal(strokes, 2);
    const colours = cr.calls.filter(c => c[0] === 'setSourceRGBA');
    assert.deepEqual(colours[1].slice(1, 4), YELLOW);

    const used = recorder();
    paintGauge(used, 88, 88, window('w', 0));
    assert.equal(used.calls.filter(c => c[0] === 'stroke').length, 1);
    assert.deepEqual(used.calls.find(c => c[0] === 'setSourceRGBA').slice(1, 4), RED);

    const empty = recorder();
    paintGauge(empty, 88, 88, null);
    assert.equal(empty.calls.filter(c => c[0] === 'stroke').length, 1, 'a placeholder is a track alone');
});

test('marks: each Provider draws something and the blossom path parses to the end', () => {
    for (const provider of ['codex', 'claudeCode', 'openCode']) {
        const cr = recorder();
        drawMark(cr, provider, 17);
        assert.ok(cr.calls.some(c => c[0] === 'fill'), provider);
    }
    const cr = recorder();
    drawMark(cr, 'codex', 17);
    assert.ok(cr.calls.filter(c => c[0] === 'curveTo').length >= 30, 'the blossom is mostly curves');
    assert.ok(cr.calls.filter(c => c[0] === 'closePath').length >= 7, 'with its holes');
});

test('canvas adapter speaks Cairo: a fill ends the path, a rule lasts one fill', () => {
    const calls = [];
    const ctx = new Proxy({}, {
        get: (_t, name) => (...a) => calls.push([name, ...a]),
        set: (_t, name, value) => { calls.push(['=' + String(name), value]); return true; },
    });
    const cr = new CairoCanvas(ctx);
    cr.setSourceRGBA(1, 0, 0, 0.5);
    cr.setFillRule(1);
    cr.rectangle(0, 0, 4, 4);
    cr.fill();
    cr.rectangle(1, 1, 1, 1);
    cr.fill();
    const fills = calls.filter(c => c[0] === 'fill');
    assert.deepEqual(fills, [['fill', 'evenodd'], ['fill', 'nonzero']]);
    assert.ok(calls.some(c => c[0] === '=fillStyle' && c[1] === 'rgba(255,0,0,0.5)'));
});
