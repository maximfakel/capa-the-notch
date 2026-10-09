// Run with: node --test linux/js/test/capacity.test.js
import assert from 'node:assert/strict';
import test from 'node:test';

import {Gfx, RecordingText} from '../ui/gfx.js';
import {Metrics, Type} from '../ui/metrics.js';
import {drawCapacityPage, offeredMarks} from '../ui/pages/capacity.js';
import {drawGauge, gaugeResetText, resetCountdown} from '../ui/widgets.js';
import {drawMark} from '../marks.js';
import {clock, languageClock, setClockFormat, setLanguage} from '../ui/format.js';

/** A context that remembers nothing and accepts anything. */
const blackHole = () => new Proxy({}, {get: () => () => {}});

/** A context that remembers the colours it was given. */
function colourRecorder() {
    const sources = [];
    return {sources, cr: new Proxy({}, {get: (_, k) => k === 'setSourceRGBA' ? (...c) => sources.push(c) : () => {}})};
}

const NOW = 1_700_000_000;

const win = (id, label, remaining, extra = {}) => ({
    id, label, remainingPercentage: remaining, remainingFraction: remaining / 100,
    pace: 'sustainable', resetsAt: NOW + 3600, ...extra,
});

const view = (provider, name, extra = {}) => ({
    provider, name, state: 'fresh', guidance: null, reasonRepeatsTheChip: false, needsAPersonFirst: false,
    monthUsedUp: null, switchedOff: false, windows: [], ...extra,
});

function fakeScene({pressed = null} = {}) {
    return {
        hits: [], travel: 0,
        addHit(h) { this.hits.push(h); },
        isHovered: () => false,
        isPressed: id => id === pressed,
    };
}

function page(providers, {showsKapa = false, scene = fakeScene(), extra = {}} = {}) {
    const text = new RecordingText();
    const g = new Gfx(blackHole(), text);
    const kapas = [];
    const model = {
        providers, showsKapa, expanded: true, selectedPage: 'capacity', scene, highlighted: null,
        capacityFocus: shown => ({provider: shown[0].provider, expression: 'calm'}),
        drawKapa: (_g, key, x, y, size, expression, options) => kapas.push({key, x, y, size, expression, options}),
        refresh: () => {}, connect: () => {}, openSettings: () => {}, ...extra,
    };
    const box = {x: 0, y: 38, width: 560};
    drawCapacityPage(g, scene, box, model);
    return {calls: text.calls, scene, kapas, box};
}

test('the countdown says it in the fewest words that stay honest', () => {
    const at = s => resetCountdown(NOW + s, NOW);
    assert.equal(at(-5), 'moments');
    assert.equal(at(30), 'under a minute');
    assert.equal(at(5 * 60), '5m');
    assert.equal(at(3600), '1h');
    assert.equal(at(3600 + 25 * 60), '1h 25m');
    assert.equal(at(24 * 3600), '1d');
    assert.equal(at(50 * 3600), '2d 2h');
});

test('the gauge says the time of day within a day, a countdown further off, and a dash when unknown', () => {
    assert.equal(gaugeResetText(NOW + 3600, NOW), languageClock(NOW + 3600));
    assert.equal(gaugeResetText(NOW + 50 * 3600, NOW), '2d 2h');
    assert.equal(gaugeResetText(NOW - 10, NOW), 'moments');
    assert.equal(gaugeResetText(null, NOW), '—');
});

test('a reset time keeps the language\'s clock whatever the desktop\'s; the Shelf\'s and Music\'s follow the desktop', () => {
    const at = new Date(2026, 0, 5, 23, 24).getTime() / 1000;
    try {
        for (const twelve of [true, false, null]) {
            setClockFormat(twelve);
            setLanguage('en');
            assert.match(gaugeResetText(at, at - 600), /^11:24\s?PM$/u);
            setLanguage('ru');
            assert.equal(gaugeResetText(at, at - 600), '23:24');
        }
        setLanguage('en');
        setClockFormat(false);
        assert.equal(clock(at), '23:24');
        setClockFormat(true);
        assert.match(clock(at), /^11:24\s?PM$/u);
    } finally {
        setClockFormat(null);
        setLanguage('en');
    }
});

test('the gauge works its reset out for the time it is drawn, its number in tabular figures, its words within 88', () => {
    const text = new RecordingText();
    drawGauge(new Gfx(blackHole(), text), 0, 0, win('a', '5 hour', 40, {resetsAt: NOW + 90 * 3600}), {now: NOW});
    const number = text.calls.find(c => c.str === '40%');
    assert.equal(number.font.tabular, true);
    const reset = text.calls.find(c => c.str === '3d 18h');
    assert.ok(reset, 'the countdown, from resetsAt');
    assert.equal(reset.maxWidth, 88);
    assert.equal(text.calls.find(c => c.str === '5 hour').maxWidth, 88);
});

test('nothing connected only when there are Providers and none is on', () => {
    assert.deepEqual(offeredMarks({providers: []}), []);
    const off = [view('codex', 'Codex', {switchedOff: true}), view('claudeCode', 'Claude Code', {switchedOff: true})];
    assert.equal(offeredMarks({providers: off}).length, 2);
    assert.ok(!page([]).calls.some(c => c.str === 'Connect up to two in Settings'), 'nothing known yet');
    const {calls, box} = page(off);
    const line = calls.find(c => c.str === 'Connect up to two in Settings');
    assert.equal(line.maxWidth, box.width - 36);
});

test('the nothing-connected block is centred three points low, its row 28 without Kapa and 30 with', () => {
    const off = [view('codex', 'Codex', {switchedOff: true})];
    const titleH = 13 * 1.3;
    for (const [showsKapa, rowH] of [[false, 28], [true, 30]]) {
        const {calls, box, kapas} = page(off, {showsKapa});
        const blockH = rowH + 14 + titleH + 14 + 38;
        const top = box.y + (Metrics.pageHeight - blockH) / 2 + 3;
        const line = calls.find(c => c.str === 'Connect up to two in Settings');
        assert.ok(Math.abs(line.y - (top + rowH + 14)) < 1e-9);
        assert.equal(kapas.length, showsKapa ? 1 : 0);
        if (showsKapa)
            assert.equal(kapas[0].options.awake, true);
    }
});

test('Kapa sleeps on the capacity page while another page is chosen and nothing travels', () => {
    const off = [view('codex', 'Codex', {switchedOff: true})];
    const {kapas} = page(off, {showsKapa: true, extra: {selectedPage: 'music'}});
    assert.equal(kapas[0].options.awake, false);
    const card = page([view('codex', 'Codex', {windows: [win('a', '5 hour', 50)]})], {showsKapa: true, extra: {expanded: false}});
    assert.equal(card.kapas[0].options.awake, false);
});

test('a disconnected card centres its Connect button', () => {
    const {scene, box} = page([view('codex', 'Codex', {state: 'disconnected'})]);
    const hit = scene.hits.find(h => h.id === 'connect:codex');
    const bodyX = box.x + Metrics.pageMargin + Metrics.cardPadding;
    const bodyW = box.width - 2 * Metrics.pageMargin - 2 * Metrics.cardPadding;
    assert.ok(Math.abs(hit.x - (bodyX + (bodyW - hit.w) / 2)) < 1e-9);
});

test('the refresh button answers to its 14 × 22 frame only', () => {
    const {scene, box} = page([view('codex', 'Codex', {windows: [win('a', '5 hour', 50)]})]);
    const hit = scene.hits.find(h => h.id === 'refresh:codex');
    assert.deepEqual([hit.w, hit.h], [14, 22]);
    assert.equal(hit.x, box.x + box.width - Metrics.pageMargin - Metrics.cardPadding - 14);
});

test('stale numbers are dimmed; a stale card\'s empty places are not', () => {
    // Drawn whole and laid down at half strength (`.opacity(0.5)` on the gauges): where an arc
    // crosses its track, no darker than either.
    const painted = [];
    const cr = new Proxy({}, {get: (_, k) => k === 'paintWithAlpha' ? a => painted.push(a) : () => {}});
    const text = new RecordingText();
    drawCapacityPage(new Gfx(cr, text), fakeScene(), {x: 0, y: 38, width: 560}, {
        providers: [view('codex', 'Codex', {state: 'stale', windows: [win('a', '5 hour', 50)]})], showsKapa: false,
        highlighted: null, refresh: () => {}, connect: () => {},
    });
    assert.deepEqual(painted, [0.5]);
    assert.equal(text.calls.find(c => c.str === '50%').rgba[3], 1);
    const recorder = colourRecorder();
    const g = new Gfx(recorder.cr, new RecordingText());
    drawCapacityPage(g, fakeScene(), {x: 0, y: 38, width: 560}, {
        providers: [view('codex', 'Codex', {state: 'stale'})], showsKapa: false, highlighted: null,
        refresh: () => {}, connect: () => {},
    });
    // The placeholder bars: 0.1 and 0.08 white, undimmed.
    assert.ok(recorder.sources.some(c => c[3] === 0.1));
    assert.ok(recorder.sources.some(c => c[3] === 0.08));
});

test('a wide card says how much is used from usedPercentage, each line no wider than its cell leaves', () => {
    const {calls, box} = page([view('codex', 'Codex', {windows: [win('a', '5 hour', 50, {usedPercentage: 51})]})]);
    const used = calls.find(c => c.str === '51% used');
    assert.ok(used);
    const bodyW = box.width - 2 * Metrics.pageMargin - 2 * Metrics.cardPadding;
    assert.equal(used.maxWidth, bodyW - 88 - 14);
});

test('a chip short of room shrinks to 85% before it gives out', () => {
    const longName = 'A Provider With A Very Long Name';
    const {calls} = page([
        view('codex', longName, {monthUsedUp: {until: null}, windows: [win('a', '5 hour', 50)]}),
        view('claudeCode', 'Claude Code', {windows: [win('a', '5 hour', 50)]}),
    ]);
    const chip = calls.find(c => c.str === 'Month used up');
    assert.ok(chip.font.size < Type.statusChip.size);
    assert.ok(chip.font.size >= Type.statusChip.size * 0.85 - 1e-9);
});

test('a plain button dims only while it is held down, as one picture', () => {
    for (const [providers, pressed] of [
        [[view('codex', 'Codex', {windows: [win('a', '5 hour', 50)]})], 'refresh:codex'],
        [[view('codex', 'Codex', {state: 'disconnected'})], 'connect:codex'],
    ]) {
        const draw = held => {
            const painted = [];
            const cr = new Proxy({}, {get: (_, k) => k === 'paintWithAlpha' ? a => painted.push(a) : () => {}});
            drawCapacityPage(new Gfx(cr, new RecordingText()), fakeScene({pressed: held}), {x: 0, y: 38, width: 560}, {
                providers, showsKapa: false, highlighted: null, refresh: () => {}, connect: () => {},
            });
            return painted;
        };
        assert.deepEqual(draw(null), []);
        assert.deepEqual(draw(pressed), [0.6]);
    }
});

test('each card has a Kapa of its own', () => {
    const {kapas} = page([
        view('codex', 'Codex', {windows: [win('a', '5 hour', 50)]}),
        view('claudeCode', 'Claude', {windows: [win('a', '5 hour', 50)]}),
    ], {showsKapa: true, extra: {capacityFocus: () => ({provider: 'claudeCode', expression: 'calm'})}});
    assert.equal(kapas.length, 1);
    assert.match(kapas[0].key, /^capacity-card:claudeCode:(26|20)$/);
});

test('OpenCode\'s mark fades with the alpha it is given', () => {
    const recorder = colourRecorder();
    drawMark(recorder.cr, 'openCode', 17, 0.5);
    assert.ok(recorder.sources.every(c => c[3] <= 0.5), 'nothing at full strength');
    assert.ok(recorder.sources.some(c => Math.abs(c[3] - 0.15) < 1e-9), 'the block at 0.3 of it');
});
