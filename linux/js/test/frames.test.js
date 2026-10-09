// Run with: node --test linux/js/test/frames.test.js
// The surface's frame chain on a clock of its own: what is drawn, and when.
import assert from 'node:assert/strict';
import test from 'node:test';

import {FrameChain, FRAME_MS, KAPA_FRAME_MS} from '../ui/frames.js';

/**
 * A scene that asks for what each test says, and a host whose drawing happens
 * after the frame that asked for it, as Clutter paints after `queue_repaint`.
 */
function rig({paint = () => {}, paintLayer = () => {}, layer = false, layers = null, screen = null} = {}) {
    let clock = 1000;
    let timers = [];
    let id = 0;
    /** What waits for the screen's next frame (`nextFrame`), the screen showing one every 1000 / 60 ms. */
    let waiting = [];
    const asked = {screen: 0};
    const scene = {
        now: 0, kapaDue: Infinity, layers: new Map(), atRest: true,
        get idle() { return this.atRest && this.kapaDue === Infinity; },
        tick(now) { this.now = now; return !this.atRest; },
        planLayers() {
            const kinds = layers ?? (layer ? {row: {kind: 'row', shared: true}} : {});
            const was = this.layers;
            this.layers = new Map(Object.entries(kinds).map(([key, k]) => [key, {...k, due: Infinity, fresh: !was.has(key)}]));
        },
        modulesNeedFrames: () => false,
        timedRedrawDelay: () => Infinity,
    };
    const drawn = {whole: [], layer: []};
    let queued = {whole: false, layer: false};
    const drawnBy = {};
    const frames = new FrameChain(scene, {
        clock: () => clock,
        set: (fn, ms) => { timers.push({at: clock + ms, fn, id: ++id}); return id; },
        clear: which => { timers = timers.filter(t => t.id !== which); },
        drawWhole: () => { queued.whole = true; },
        drawLayer: key => { (queued.layers ??= []).push(key); },
        placeLayers: () => {},
        ...(screen ? {
            nextFrame: fn => {
                if (screen === 'off')
                    return 0;
                asked.screen++;
                waiting.push({fn, id: ++id});
                return id;
            },
            clearFrame: which => { waiting = waiting.filter(w => w.id !== which); },
        } : {}),
    });
    const run = ms => {
        const end = clock + ms;
        for (;;) {
            timers.sort((a, b) => a.at - b.at);
            const vsync = waiting.length ? (Math.floor(clock / (1000 / 60) + 1e-9) + 1) * (1000 / 60) : Infinity;
            const timer = timers.length ? timers[0].at : Infinity;
            if (Math.min(vsync, timer) > end)
                break;
            if (vsync <= timer) {
                clock = vsync;
                const now = waiting;
                waiting = [];
                now.forEach(w => w.fn());
            } else {
                const t = timers.shift();
                clock = t.at;
                t.fn();
            }
            if (queued.whole) {
                queued.whole = false;
                scene.kapaDue = Infinity;
                paint(scene);
                drawn.whole.push(clock);
                frames.painted('whole');
            }
            for (const key of queued.layers ?? []) {
                const layer = scene.layers.get(key);
                layer.due = Infinity;
                paintLayer(scene, layer, key);
                drawn.layer.push(clock);
                (drawnBy[key] ??= []).push(clock);
                frames.painted('layer', key);
            }
            queued.layers = [];
        }
        clock = end;
    };
    return {scene, frames, drawn, drawnBy, run, asked, pending: () => timers.map(t => t.at - clock), waiting: () => waiting.length, now: () => clock};
}

const gaps = times => times.slice(1).map((t, i) => Math.round(t - times[i]));

test('a frame asked for while the surface is drawn comes, with nothing else to wake it', () => {
    let asks = 1;
    const r = rig({paint: scene => {
        if (asks-- > 0)
            scene.kapaDue = scene.now + 0.2;
    }});
    r.frames.wake();
    r.run(1000);
    assert.equal(r.drawn.whole.length, 2);
    assert.deepEqual(gaps(r.drawn.whole), [200]);
});

test('Kapa is drawn when she asked, at most every thirtieth of a second, and not once more when she stops', () => {
    // Moving for five frames, then still until a blink a second away.
    let moving = 5;
    const r = rig({paint: scene => {
        scene.kapaDue = moving-- > 0 ? scene.now + 1 / 30 : scene.now + 1;
    }});
    r.frames.wake();
    r.run(1200);
    assert.deepEqual(gaps(r.drawn.whole), [33, 33, 33, 33, 33, 1000]);
});

test('the row layer\'s bars are drawn at their own 24 a second, the surface left as it is', () => {
    const r = rig({layer: true, paintLayer: (scene, layer) => {
        layer.due = scene.now + 1 / 24;
    }});
    r.frames.wake();
    r.run(1000);
    assert.equal(r.drawn.whole.length, 1);
    assert.ok(gaps(r.drawn.layer).every(g => g === 42), gaps(r.drawn.layer).join(' '));
    assert.equal(r.drawn.layer.length, 24);
});

test('the layer may ask for the surface: what of Kapa floats over the strip is the surface\'s', () => {
    let over = 3;
    const r = rig({layer: true, paintLayer: (scene, layer) => {
        layer.due = scene.now + 1 / 30;
        if (over-- > 0)
            scene.kapaDue = Math.min(scene.kapaDue, scene.now);
    }});
    r.frames.wake();
    r.run(1000);
    // The first frame draws both; the layer's next three asks each bring the surface once more.
    assert.equal(r.drawn.whole.length, 4);
    assert.equal(r.drawn.layer.length, 30);
});

test('a state arriving does not bring forward a frame already coming within a Kapa frame', () => {
    const r = rig({paint: scene => {
        scene.kapaDue = scene.now + 1 / 30;
    }});
    r.frames.wake();
    r.run(FRAME_MS);
    assert.equal(r.drawn.whole.length, 1);
    r.run(5);
    r.frames.wake(KAPA_FRAME_MS);
    assert.deepEqual(r.pending(), [28], 'the frame 28 ms away stands');
    r.frames.wake();
    assert.deepEqual(r.pending(), [FRAME_MS], 'a change of the surface\'s own is drawn on the next frame');
    // Nothing coming: the next frame, as ever.
    const idle = rig();
    idle.frames.wake(KAPA_FRAME_MS);
    assert.deepEqual(idle.pending(), [FRAME_MS]);
});

test('one chain of frames, ever, at the soonest asked for', () => {
    const r = rig();
    r.frames.stale = false;
    r.frames.schedule(100);
    r.frames.schedule(50, 'row');
    r.frames.schedule(200);
    assert.deepEqual(r.pending(), [50]);
    r.run(60);
    // The layer's frame drew nothing (no layer); the surface's 100 still stands.
    assert.deepEqual(r.pending(), [40]);
    r.run(100);
    assert.equal(r.drawn.whole.length, 1);
    assert.deepEqual(r.pending(), []);
});

test('each layer is drawn at its own moment, the surface left as it is', () => {
    // A Kapa at her thirty a second, a capsule at its own, and the surface drawn once.
    const r = rig({layers: {'kapa:hello': {kind: 'kapa'}, 'overlay:dictation': {kind: 'overlay'}}, paintLayer: (scene, layer, key) => {
        layer.due = scene.now + (key === 'kapa:hello' ? 1 / 30 : 0.1);
    }});
    r.frames.wake();
    r.run(1000);
    assert.equal(r.drawn.whole.length, 1);
    assert.ok(gaps(r.drawnBy['kapa:hello']).every(g => g === 33), gaps(r.drawnBy['kapa:hello']).join(' '));
    assert.ok(gaps(r.drawnBy['overlay:dictation']).every(g => Math.abs(g - 100) <= 1), gaps(r.drawnBy['overlay:dictation']).join(' '));
});

test('a page\'s beat draws the surface alone: a layer whose moment has not come is left as it is, one just placed is drawn', () => {
    // The surface asks for a beat every 250 ms; her layer for a frame every 100.
    const r = rig({layers: {'kapa:music-page': {kind: 'kapa'}}, paint: scene => {
        scene.kapaDue = scene.now + 0.25;
    }, paintLayer: (scene, layer) => {
        layer.due = scene.now + 0.1;
    }});
    r.frames.wake();
    r.run(1000);
    // Drawn with the surface the first time (just placed), then only at her own moments.
    assert.deepEqual(gaps(r.drawn.whole), [250, 250, 250]);
    assert.ok(gaps(r.drawnBy['kapa:music-page']).every(g => Math.abs(g - 100) <= 1), gaps(r.drawnBy['kapa:music-page']).join(' '));
    // Something changing draws both.
    const before = r.drawnBy['kapa:music-page'].length;
    r.frames.wake();
    r.run(FRAME_MS);
    assert.equal(r.drawnBy['kapa:music-page'].length, before + 1);
    assert.equal(r.drawnBy['kapa:music-page'].at(-1), r.drawn.whole.at(-1));
});

test('a motion is drawn on the screen\'s own frames, from the next one, every one of them, and only while it moves', () => {
    // Moving for half a second from a change 5 ms after a screen frame.
    let until = Infinity;
    const r = rig({screen: true});
    r.scene.tick = function (now) { this.now = now; this.atRest = now * 1000 >= until; return !this.atRest; };
    r.run(1000 / 60 * 3 + 5 - 1000 % (1000 / 60));
    const start = r.now();
    until = start + 500;
    r.scene.atRest = false;
    r.frames.wake();
    assert.deepEqual(r.pending(), [], 'no timer: the screen\'s next frame');
    r.run(1000);
    const vsync = 1000 / 60;
    assert.ok(r.drawn.whole[0] - start < vsync, `the first frame ${r.drawn.whole[0] - start} ms after the change`);
    const gapsMs = r.drawn.whole.slice(1).map((t, i) => t - r.drawn.whole[i]);
    assert.ok(gapsMs.every(g => Math.abs(g - vsync) < 1e-6), gapsMs.join(' '));
    assert.ok(r.drawn.whole.at(-1) >= until, 'the last frame is the one that stands at rest');
    assert.equal(r.waiting(), 0, 'and then nothing waits for the screen');
    assert.equal(r.pending().length, 0);
});

test('a screen that cannot give a frame leaves the motion to the timers', () => {
    let frames = 0;
    const r = rig({screen: 'off', paint: () => { frames++; }});
    r.scene.tick = function (now) { this.now = now; return frames < 5; };
    r.frames.wake();
    assert.deepEqual(r.pending(), [FRAME_MS]);
    r.run(1000);
    // Five moving, and the one that stands at rest.
    assert.equal(r.drawn.whole.length, 6);
    assert.deepEqual(gaps(r.drawn.whole), [16, 16, 16, 16, 16]);
});

test('one chain still, with the screen: a Kapa frame far off gives way to the screen\'s next, and never stands beside it', () => {
    const r = rig({screen: true});
    r.frames.stale = false;
    r.frames.schedule(KAPA_FRAME_MS);
    assert.deepEqual(r.pending(), [KAPA_FRAME_MS]);
    r.frames.wake();
    assert.deepEqual(r.pending(), [], 'the timer is taken back');
    assert.equal(r.waiting(), 1);
    r.frames.wake();
    assert.equal(r.waiting(), 1, 'asked twice, one frame');
    r.run(100);
    assert.equal(r.drawn.whole.length, 1);
    assert.equal(r.waiting(), 0);
});
