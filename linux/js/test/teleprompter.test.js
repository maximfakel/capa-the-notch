// Run with: node --test linux/js/test/*.test.js
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';

import {RecordingText, Gfx} from '../ui/gfx.js';
import {SurfaceScene} from '../ui/scene.js';
import teleprompter from '../ui/modules/teleprompter.js';
import * as L from '../ui/modules/teleprompter-layout.js';

const fixture = JSON.parse(readFileSync(new URL('./fixtures/teleprompter.json', import.meta.url)));
const close = (a, b, msg) => assert.ok(Math.abs(a - b) < 1e-9, `${msg}: ${a} vs ${b}`);

/** A drawing context that remembers what it was asked, with a clip stack so clipped drawing can be told. */
function recorder() {
    const calls = [];
    const proxy = new Proxy({calls}, {get: (t, name) => name === 'calls' ? calls : (...args) => { calls.push([name, ...args]); }});
    return proxy;
}

const lines = ['One.', 'Two.', 'Three.', 'Four.', 'Five.', 'Six.', 'Seven.', 'Eight.'];

function module(state, extra = {}) {
    const now = Date.now();
    return {
        enabled: true, showingRow: state !== 'stopped', textSize: 'medium', lines, wordCount: 8, minutes: 1,
        hasPreviousScript: false, hoverOpens: state !== 'running', excludedFromCapture: true, serverNowMs: now,
        spoken: `Teleprompter, ${state}`,
        motion: {anchor: 2, anchoredAtMs: now - 2000, linesPerSecond: 0.5, lastLine: 7},
        playback: {state, isShowing: state !== 'stopped', multiplier: 1, wordsPerMinute: 130, position: 2, progress: 2 / 7,
            elapsedSeconds: 4, remainingSeconds: 10, durationSeconds: 14},
        ...extra,
    };
}

function sceneWith(tp) {
    const calls = [];
    const scene = new SurfaceScene({barHeight: 38, notchWidth: 0}, {
        call: (m, method, args) => { calls.push([m, method, args]); return Promise.resolve(); },
        readClipboard: async () => 'clip text',
        openSettings: section => calls.push(['settings', section]),
    });
    scene.setModel({providers: [], pages: ['capacity', 'teleprompter'], modules: {teleprompter: tp}});
    return {scene, calls};
}

function draw(scene) {
    const text = new RecordingText();
    const cr = recorder();
    scene.draw(new Gfx(cr, text), {width: 608, height: 260});
    return {text, cr};
}

test('the layout numbers are the Rust\'s', () => {
    for (const s of fixture.sizes) {
        close(L.pointsOf(s.size), s.points, 'points');
        assert.equal(L.lineHeight(s.size), s.lineHeight, `${s.size} line height`);
        assert.equal(L.pitch(s.size), s.pitch);
        close(L.kern(s.size), s.kern, 'kern');
        assert.equal(L.rowLines(s.size), s.rowLines, `${s.size} row lines`);
        assert.equal(L.textAreaHeight(s.size), s.textAreaHeight);
        assert.equal(L.ROW_HEIGHT, s.rowHeight);
        assert.equal(L.previewHeight(s.size), s.previewHeight);
        s.fadeBands.forEach((b, i) => {
            const mine = L.fadeBands(s.size)[i];
            close(mine.from, b.from, 'band from');
            close(mine.to, b.to, 'band to');
            close(mine.opacity, b.opacity, 'band opacity');
        });
        [0, 0.5, 3.2, 40].forEach((p, i) => assert.deepEqual(L.linesToDraw(p, s.size, 100), s.linesToDraw[i], `${s.size} at ${p}`));
    }
    fixture.opacity.forEach((o, row) => close(L.lineOpacity(row), o, `opacity ${row}`));
    [[300, 0], [300, 0.5], [300, 2]].forEach(([w, f], i) => close(L.progressFillWidth(w, f), fixture.progressFill[i], 'fill'));
    [0.5, 1, 1.25, 2].forEach((m, i) => assert.equal(L.speedText(m), fixture.speedText[i]));
});

test('the row is as drawn: six lines at the smaller sizes, five at the largest, 172 under the strip', () => {
    assert.deepEqual(['small', 'medium', 'large'].map(L.rowLines), [6, 6, 5]);
    assert.equal(L.ROW_HEIGHT, 172);
    assert.equal(38 + L.ROW_HEIGHT, 210);
});

test('a running Script is carried on from its anchor, held at the start and stopped at the last line', () => {
    const tp = module('running');
    const at = ms => L.positionAt(tp, tp.serverNowMs + ms);
    close(at(0), 2 + 2 * 0.5, 'two seconds after the anchor');
    close(at(-5000), 2, 'before the anchor it holds');
    close(at(1e7), 7, 'never past the last line');
    assert.equal(L.positionAt(module('paused'), 0), 2, 'paused, where it was put');
    close(L.progressAt(module('paused'), 0), 2 / 7, 'progress');
    assert.equal(L.clockText(75), '01:15');
    assert.equal(L.clockText(-3), '00:00');
});

test('the compact row exists only while the Script shows, takes the music row\'s place and is wide', () => {
    assert.equal(teleprompter.compactRow({module: module('stopped')}), null);
    assert.equal(teleprompter.compactRow({module: undefined}), null);
    const row = teleprompter.compactRow({module: module('paused')});
    assert.equal(row.height, 172);
    assert.equal(row.width, 560);
    assert.equal(row.wide, true);
    assert.ok(row.priority > 10, 'above a music row');
});

test('while it runs a passing pointer does not open the surface, and the page button carries a dot', () => {
    assert.equal(teleprompter.hoverOpens({module: module('running')}), false);
    assert.equal(teleprompter.hoverOpens({module: module('paused')}), true);
    assert.equal(teleprompter.hoverOpens({}), true);
    assert.equal(teleprompter.running({module: module('running')}), true);
    assert.equal(teleprompter.running({module: module('paused')}), false);
});

test('frames are asked for only while the Script moves where it can be seen', () => {
    const running = module('running');
    assert.equal(teleprompter.needsFrames({module: running, expanded: false}), true, 'the row, closed');
    assert.equal(teleprompter.needsFrames({module: running, expanded: true, selectedPage: 'capacity'}), false, 'another page is open');
    assert.ok(teleprompter.needsFrames({module: running, expanded: true, selectedPage: 'teleprompter'}), 'the page');
    assert.equal(teleprompter.needsFrames({module: module('paused'), expanded: false}), false);
});

test('the page, and the row under Reduce Motion, ask for a frame at the next quarter second from the anchor, not every frame', () => {
    const realNow = Date.now;
    try {
        const from = 1_800_000_000_037;
        const running = module('running', {motion: {anchor: 2, anchoredAtMs: from, linesPerSecond: 0.5, lastLine: 7}});
        const {scene} = sceneWith(running);
        const page = {module: running, expanded: true, selectedPage: 'teleprompter', scene};
        const row = {module: running, expanded: false, scene};

        Date.now = () => from + 1100;
        assert.deepEqual(teleprompter.needsFrames(page), {interval: 0.15}, 'the page: 150 ms to the tick at 1250');
        assert.equal(teleprompter.needsFrames(row), true, 'the gliding row: every frame');
        scene.setModel({reduceMotion: true});
        assert.deepEqual(teleprompter.needsFrames(row), {interval: 0.15}, 'the stepped row: the same beat');
        Date.now = () => from + 1250;
        assert.deepEqual(teleprompter.needsFrames(row), {interval: 0.25}, 'on a tick, the next one');

        // What the scene makes of it: a beat, never every frame.
        Date.now = () => from + 1100;
        assert.equal(scene.modulesNeedFrames(), false);
        close(scene.moduleFrameInterval(), 0.15, 'the closed row\'s beat');
        scene.expand();
        scene.select('teleprompter');
        close(scene.moduleFrameInterval(), 0.15, 'the page\'s beat');

        // Nothing drawn between two ticks differs from what was drawn at the first.
        const at = ms => { Date.now = () => from + ms; return draw(scene).text.calls.map(c => `${c.str}@${c.x},${c.y},${c.rgba}`).join('|'); };
        assert.equal(at(1250), at(1499), 'one tick, one picture');
        assert.notEqual(at(1499), at(3500), 'and the next tick moves it');
    } finally {
        Date.now = realNow;
    }
});

test('the scene gives the row 210 under the strip while the Script shows, and the strip alone when it does not', () => {
    const {scene} = sceneWith(module('paused'));
    assert.equal(scene.compactSize.height, 38 + 172);
    assert.equal(scene.compactSize.width, 560);
    const {scene: stopped} = sceneWith(module('stopped'));
    assert.equal(stopped.compactSize.height, 38);
});

test('the row draws the lines in view and its two controls, and a click on it pauses', () => {
    const {scene, calls} = sceneWith(module('running'));
    scene.setModel({}); // retarget
    scene.width.set(560);
    scene.height.set(210);
    scene.content.value = 0;
    const {text} = draw(scene);
    const drawn = text.calls.map(c => c.str);
    // Two seconds in at half a line a second from line 2: the place is line 3, so Four. is the one read.
    assert.ok(drawn.includes('Four.') && drawn.includes('Five.') && drawn.includes('Six.'), `${drawn}`);
    assert.ok(!drawn.includes('One.'), 'a line that has left is not drawn');
    const ids = scene.hits.map(h => h.id);
    assert.ok(ids.includes('tp-row') && ids.includes('tp-row-toggle') && ids.includes('tp-row-stop'), `${ids}`);
    const toggle = scene.hits.find(h => h.id === 'tp-row-toggle');
    scene.click(toggle.x + 2, toggle.y + 2);
    assert.deepEqual(calls.at(-1), ['teleprompter', 'toggle', null]);
    const stop = scene.hits.find(h => h.id === 'tp-row-stop');
    scene.click(stop.x + 2, stop.y + 2);
    assert.deepEqual(calls.at(-1), ['teleprompter', 'stop', null]);
    const row = scene.hits.find(h => h.id === 'tp-row');
    scene.click(row.x + 300, row.y + 20);
    assert.deepEqual(calls.at(-1), ['teleprompter', 'toggle', null]);
    // The gap under the strip is the row's too, and it is heard as the state.
    assert.equal(row.y, 38);
    assert.equal(row.h, L.STRIP_GAP + L.textAreaHeight('medium'));
    assert.equal(row.label, 'Teleprompter, running');
});

test('a line between two bands passes evenly from one brightness to the next, through one gradient mask', () => {
    // 3.3 lines in: "Five." straddles the gap under the first line.
    const now = Date.now();
    const {scene} = sceneWith(module('running', {motion: {anchor: 2, anchoredAtMs: now - 2600, linesPerSecond: 0.5, lastLine: 7}}));
    scene.width.set(560); scene.height.set(210); scene.content.value = 0;
    const {text, cr} = draw(scene);
    const five = text.calls.filter(c => c.str === 'Five.');
    assert.equal(five.length, 1, 'each line drawn once');
    close(five[0].rgba[3], 1, 'at full white: the mask fades it');

    // The lines go to a group, laid down through a vertical gradient down the text area.
    const names = cr.calls.map(c => c[0]);
    const push = names.indexOf('pushGroup'), pop = names.indexOf('popGroupToSource'), mask = names.indexOf('mask');
    assert.ok(push >= 0 && push < pop && pop < mask, `${names}`);
    const [, x0, y0, x1, y1, maskStops] = cr.calls.find(c => c[0] === 'linearGradient');
    const top = 38 + L.STRIP_GAP, height = L.textAreaHeight('medium');
    assert.deepEqual([x0, y0, x1, y1], [0, top, 0, top + height]);
    const stops = L.fadeStops('medium');
    assert.equal(maskStops.length, stops.length);
    maskStops.forEach(([offset, r, g, b, a], i) => {
        close(offset * height, stops[i][0], `stop ${i} at its place`);
        assert.deepEqual([r, g, b], [1, 1, 1]);
        close(a, stops[i][1], `stop ${i} its opacity`);
    });
    assert.ok(!names.includes('fillRect'), 'no slices');

    assert.equal(stops.length, 2 * L.rowLines('medium'));
    const next = 0x8C / 255;
    close(L.fadeOpacityAt(stops, 25), (1 + next) / 2, 'half way across the gap, half way between');
    close(L.fadeOpacityAt(stops, 10), 1, 'within a line, its band');
    close(L.fadeOpacityAt(stops, 1e4), L.lineOpacity(5), 'held after the last');
});

test('with nothing to mask with, each line is drawn at the fade where its middle is', () => {
    const now = Date.now();
    const {scene} = sceneWith(module('running', {motion: {anchor: 2, anchoredAtMs: now - 2600, linesPerSecond: 0.5, lastLine: 7}}));
    scene.width.set(560); scene.height.set(210); scene.content.value = 0;
    const text = new RecordingText();
    const cr = recorder();
    const plain = new Proxy(cr, {get: (t, name) => ['pushGroup', 'mask', 'linearGradient'].includes(name) ? undefined : t[name]});
    scene.draw(new Gfx(plain, text), {width: 608, height: 260});
    const five = text.calls.filter(c => c.str === 'Five.');
    assert.equal(five.length, 1);
    const y = five[0].y - 38 - L.STRIP_GAP;
    close(five[0].rgba[3], L.fadeOpacityAt(L.fadeStops('medium'), y + L.lineHeight('medium') / 2), 'its middle\'s opacity');
});

test('under Reduce Motion the row moves a whole line at a time', () => {
    const now = Date.now();
    const {scene} = sceneWith(module('running', {motion: {anchor: 2, anchoredAtMs: now - 2600, linesPerSecond: 0.5, lastLine: 7}}));
    scene.setModel({reduceMotion: true});
    scene.width.set(560); scene.height.set(210); scene.content.value = 0;
    const {text} = draw(scene);
    const four = text.calls.filter(c => c.str === 'Four.');
    assert.equal(four.length, 1, 'at rest in its band');
    assert.equal(four[0].y, 38 + L.STRIP_GAP + L.TOP_INSET, 'on the first line, not 0.3 of a line above it');
    close(four[0].rgba[3], 1, 'full white');
});

test('the clock the page reads by ticks four times a second while the Script runs', () => {
    const running = module('running');
    const from = running.motion.anchoredAtMs;
    assert.equal(L.steppedAt(running, from + 1249), from + 1000);
    assert.equal(L.steppedAt(running, from + 1250), from + 1250);
    assert.equal(L.steppedAt(module('paused'), 1234), 1234, 'not running, now');
});

test('a Script on screen is kept out of what is shared', () => {
    assert.equal(teleprompter.excludesFromCapture({module: module('running')}), true);
    assert.equal(teleprompter.excludesFromCapture({module: module('stopped')}), false);
    assert.equal(teleprompter.excludesFromCapture({}), false);
});

test('a line at rest in the first band is drawn once, full white', () => {
    const {scene} = sceneWith(module('paused', {}));
    scene.width.set(560); scene.height.set(210); scene.content.value = 0;
    const {text} = draw(scene);
    const alphas = text.calls.filter(c => c.str === 'Three.').map(c => c.rgba[3].toFixed(3));
    // Position 2 puts "Three." exactly in the first band: one brightness, full.
    assert.deepEqual(alphas, ['1.000']);
});

test('the page draws the three lines, progress, time, controls, Paste and Edit Script', () => {
    const {scene, calls} = sceneWith(module('paused'));
    scene.select('teleprompter');
    scene.pagePosition.set(1);
    scene.selected = 'teleprompter';
    scene.expand();
    scene.width.set(560); scene.height.set(210); scene.content.value = 1;
    const {text} = draw(scene);
    const drawn = text.calls.map(c => c.str);
    for (const s of ['Three.', 'Four.', 'Five.', '00:04', 'Paste', 'Edit Script', '1.00x'])
        assert.ok(drawn.includes(s), `${s} in ${drawn}`);
    const alpha = s => text.calls.find(c => c.str === s).rgba[3];
    assert.equal(text.calls.find(c => c.str === '1.00x').font.tabular, true, 'the speed in figures that keep their places');
    close(alpha('Three.'), 1, 'current');
    close(alpha('Four.'), 0x8C / 255, 'next');
    close(alpha('Five.'), 0x40 / 255, 'after');

    const press = id => { const h = scene.hits.find(x => x.id === id); scene.click(h.x + h.w / 2, h.y + h.h / 2); };
    press('tp-toggle');
    press('tp-stop');
    press('tp-faster');
    press('tp-slower');
    assert.deepEqual(calls.map(c => c[1]), ['toggle', 'stop', 'faster', 'slower']);
    press('tp-edit');
    assert.deepEqual(calls.at(-1), ['settings', 'modules']);
});

test('the page\'s controls stand where their symbols\' widths put them', () => {
    const {scene} = sceneWith(module('paused'));
    scene.select('teleprompter'); scene.pagePosition.set(1); scene.selected = 'teleprompter'; scene.expand();
    scene.width.set(560); scene.height.set(210); scene.content.value = 1;
    const {text} = draw(scene);
    const hit = id => scene.hits.find(h => h.id === id);
    const play = L.controlWidth.play(14), stop = L.controlWidth.stop(14), minus = L.controlWidth.minus(13), plus = L.controlWidth.plus(13);
    close(minus, 12.298, 'minus, 13 points');
    close(plus, minus, 'plus as wide');
    const x = hit('tp-toggle').x;
    close(hit('tp-toggle').w, play, 'play.fill');
    close(hit('tp-stop').x, x + play + 8, 'eight after play');
    close(hit('tp-stop').w, stop, 'stop.fill');
    close(hit('tp-slower').x + 3, x + play + 8 + stop + 8, 'eight after stop');
    const speed = text.calls.find(c => c.str === '1.00x');
    close(speed.x, x + play + 8 + stop + 8 + minus + 10, 'the speed ten after minus');
    close(hit('tp-faster').x + 3, speed.x + speed.width + 10, 'plus ten after the speed');
    close(hit('tp-faster').w, plus + 6, 'plus, three points round it');
});

test('Paste reads the clipboard at the click and sends it', async () => {
    const {scene, calls} = sceneWith(module('stopped'));
    scene.expand(); scene.selected = 'teleprompter'; scene.pagePosition.set(1);
    scene.width.set(560); scene.height.set(210); scene.content.value = 1;
    draw(scene);
    const h = scene.hits.find(x => x.id === 'tp-paste');
    scene.click(h.x + 2, h.y + 2);
    await new Promise(r => setTimeout(r, 0));
    assert.deepEqual(calls.at(-1), ['teleprompter', 'paste', {text: 'clip text'}]);
});

test('an empty Script says how to get one, and cannot be started', () => {
    const {scene} = sceneWith(module('stopped', {lines: [], motion: {anchor: 0, anchoredAtMs: 0, linesPerSecond: 0, lastLine: 0}}));
    scene.expand(); scene.selected = 'teleprompter'; scene.pagePosition.set(1);
    scene.width.set(560); scene.height.set(210); scene.content.value = 1;
    const {text} = draw(scene);
    const hint = text.calls.find(c => c.str === 'Paste a Script, or write one in Settings.');
    assert.ok(hint);
    assert.deepEqual([hint.font.size, hint.font.weight, hint.font.kern ?? 0], [17, 500, 0], 'Geist Medium at the size, not tracked');
    assert.ok(!scene.hits.some(h => h.id === 'tp-toggle'), 'no start without a Script');
});

test('dragging the progress seeks where it was let go', () => {
    const {scene, calls} = sceneWith(module('paused'));
    scene.expand(); scene.selected = 'teleprompter'; scene.pagePosition.set(1);
    scene.width.set(560); scene.height.set(210); scene.content.value = 1;
    draw(scene);
    const bar = scene.hits.find(h => h.id === 'tp-progress');
    // Six points round the bar are its too (`.contentShape(Rectangle().inset(by: -6))`).
    const track = {x: bar.x + 6, w: bar.w - 12};
    assert.equal(bar.h, 16);
    scene.press(bar.x + 2, bar.y + 2);
    assert.equal(scene.tpDrag, 0, 'left of the bar is its start');
    scene.setPointer({x: track.x + track.w * 0.75, y: bar.y + 8});
    assert.ok(Math.abs(scene.tpDrag - 0.75) < 1e-9);
    assert.ok(scene.release());
    assert.equal(calls.at(-1)[1], 'seek');
    assert.ok(Math.abs(calls.at(-1)[2].fraction - 0.75) < 1e-9);
    assert.equal(scene.tpDrag, null);
});

test('two fingers on the row move the Script by the lines they travelled', () => {
    const {scene, calls} = sceneWith(module('running'));
    assert.equal(scene.scrollCompactRow(48), true);
    assert.equal(calls.at(-1)[1], 'moveByLines');
    close(calls.at(-1)[2].lines, 48 / L.pitch('medium'), 'lines');
    const {scene: stopped} = sceneWith(module('stopped'));
    assert.equal(stopped.scrollCompactRow(48), false, 'no row, nothing to move');
});

test('running, the Script\'s lines are on the row\'s layer: drawn there alone, the row\'s controls and hits kept by the surface', () => {
    const {scene} = sceneWith(module('running'));
    scene.liveLayers = true;
    scene.tick(10);
    assert.equal(scene.rowLayerReady(), true, 'closed and still, with lines that move');
    const ctx = {...scene.pageModel(), module: scene.model.modules.teleprompter, expanded: false, selectedPage: 'capacity'};
    assert.ok(teleprompter.needsFrames(ctx), 'drawn by the surface, the surface asks for every frame');
    scene.planLayers();
    assert.deepEqual([...scene.layers.keys()], ['row']);
    assert.ok(!teleprompter.needsFrames({...ctx, rowLayer: true}), 'on the layer, the surface asks for nothing');

    const {text} = draw(scene);
    assert.ok(!text.calls.some(c => lines.includes(c.str)), 'the surface leaves the lines out');
    assert.ok(['tp-row', 'tp-row-toggle', 'tp-row-stop'].every(id => scene.hits.some(h => h.id === id)), 'and keeps what answers');
    assert.equal(scene.kapaDue, Infinity);

    const layer = new RecordingText();
    const cr = recorder();
    const hits = scene.hits.length;
    scene.drawLayer('row', new Gfx(cr, layer), 304);
    assert.ok(layer.calls.some(c => lines.includes(c.str)), 'the layer draws them');
    assert.ok(cr.calls.some(c => c[0] === 'mask'), 'through the fade');
    assert.equal(scene.hits.length, hits, 'a layer takes no hits');
    assert.equal(scene.layerDue, scene.now, 'and asks for its next frame');
    // The rectangle the host gives the layer is the text area, under the strip.
    const r = scene.rowLayerRect(304);
    assert.equal(r.y, 38 + L.STRIP_GAP);
    assert.equal(r.w, L.ROW_WIDTH);
});
