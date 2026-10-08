// Run with: node --test linux/js/test
// Kapa's logic is checked against `fixtures/kapa.json`, which is written from
// the Rust (`linux/crates/core/src/kapa/tests.rs`); the drawing is checked with a
// recording context, since pixels are for the pictures.

import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';

import {CairoCanvas} from '../cairo-canvas.js';
import {
    CairoGjs, EXPRESSIONS, KapaBlink, KapaEngine, KapaGaze, KapaMotion, capacityFocus, capacityMood, drawKapa, faceEquals,
    faceOf, musicMood, urgency,
} from '../ui/kapa/index.js';
import {drawBadge, drawHeadphones} from '../ui/kapa/paths.js';

const fixture = JSON.parse(readFileSync(new URL('./fixtures/kapa.json', import.meta.url), 'utf8'));

/** Numbers within a rounding error, everything else exactly. */
function same(actual, expected, at = 'value') {
    if (typeof expected === 'number') {
        assert.equal(typeof actual, 'number', `${at}: not a number`);
        assert.ok(Math.abs(actual - expected) <= 1e-9 * Math.max(1, Math.abs(expected)), `${at}: ${actual} != ${expected}`);
    } else if (Array.isArray(expected)) {
        assert.equal(actual.length, expected.length, `${at}: length`);
        expected.forEach((e, i) => same(actual[i], e, `${at}[${i}]`));
    } else if (expected && typeof expected === 'object') {
        for (const key of Object.keys(expected)) same(actual[key], expected[key], `${at}.${key}`);
    } else {
        assert.equal(actual, expected, at);
    }
}

// MARK: - The logic, against the Rust

test('every pose draws the face the Rust says', () => {
    assert.deepEqual([...EXPRESSIONS].sort(), Object.keys(fixture.faces).sort(), 'the same poses');
    for (const expression of EXPRESSIONS) same(faceOf(expression), fixture.faces[expression], expression);
});

test('every pose says it with more than colour: no two faces alike', () => {
    const faces = EXPRESSIONS.map(faceOf);
    faces.forEach((face, i) => {
        for (const other of faces.slice(i + 1))
            assert.ok(!faceEquals(face, other), `two poses draw the same face: ${JSON.stringify(face)}`);
    });
    assert.notEqual(faceOf('copied').badge, faceOf('inserted').badge);
    assert.ok(faceOf('music').headphones && faceOf('paused').headphones);
});

test('the eyes sit and turn as the Rust has them', () => {
    for (const {side, look, eye} of fixture.gaze) same(KapaGaze.eye(side, look), eye, `eye(${side}, ${JSON.stringify(look)})`);
    for (const {look, features} of fixture.features) same(KapaGaze.features(look), features, 'features');
    const left = KapaGaze.eye(-1, {yaw: 0, pitch: 0});
    const right = KapaGaze.eye(1, {yaw: 0, pitch: 0});
    assert.ok(Math.abs(left.x - 41) < 0.1 && Math.abs(right.x - 63) < 0.1, 'looking ahead, the eyes are where the sheet draws them');
    assert.ok(KapaGaze.eye(1, {yaw: 1.5, pitch: 0}).isHidden, 'an eye gone round the head is not drawn');
});

test('blinking: every two to five seconds, sometimes twice, arcs have no lids', () => {
    for (const {draw, delay, isDouble} of fixture.blink) {
        same(KapaBlink.delay(draw), delay, `delay(${draw})`);
        assert.equal(KapaBlink.isDouble(draw), isDouble, `isDouble(${draw})`);
    }
    assert.ok(!KapaBlink.blinks('happy') && !KapaBlink.blinks('closed') && KapaBlink.blinks('open'));
    for (const {elapsed, value} of fixture.lid) same(KapaMotion.lid(elapsed), value, `lid(${elapsed})`);
    assert.ok(Math.abs(KapaMotion.lid(KapaBlink.closing) - 0.08) < 0.01, 'shut at 70 ms');
    assert.equal(KapaMotion.lid(KapaBlink.closing + KapaBlink.opening), 1, 'open again by 200 ms');
});

test('the timeline gives the Rust\'s values at the Rust\'s moments', () => {
    for (const {reaction, elapsed, kick} of fixture.kicks) same(KapaMotion.kick(reaction, elapsed), kick, `${reaction}@${elapsed}`);
    for (const {elapsed, kick} of fixture.boop) same(KapaMotion.boop(elapsed), kick, `boop@${elapsed}`);
    for (const {elapsed, kick} of fixture.shake) same(KapaMotion.shake(elapsed), kick, `shake@${elapsed}`);
    for (const {elapsed, gulp} of fixture.gulp) same(KapaMotion.gulp(elapsed), gulp, `gulp@${elapsed}`);
    for (const {time, ...expected} of fixture.bob) same(KapaMotion.bob(time), expected, `bob@${time}`);
    for (const {time, ...expected} of fixture.breath) same(KapaMotion.breath(time), expected, `breath@${time}`);
    for (const {value, velocity, target, dt, next} of fixture.spring) same(KapaMotion.spring(value, velocity, target, dt), next, 'spring');
    for (const {value, target, base, dt, next} of fixture.approach) same(KapaMotion.approach(value, target, base, dt), next, 'approach');
    for (const {distance, reach, value} of fixture.appetite) same(KapaMotion.appetite(distance, reach), value, 'appetite');
});

test('the Swift tests, said again: nods on the beat, follows a target at any frame rate, opens wider the nearer', () => {
    const beat = 60 / KapaMotion.musicTempo;
    assert.ok(KapaMotion.bob(0).dy > 3 && KapaMotion.bob(beat * 0.7).dy < 0.1);
    assert.ok(Math.abs(KapaMotion.bob(beat).dy - KapaMotion.bob(0).dy) < 1e-9);
    assert.ok(KapaMotion.bob(beat / 2).tilt > 0 && KapaMotion.bob(beat * 1.5).tilt < 0);

    let thirty = 0;
    for (let i = 0; i < 30; i++) thirty = KapaMotion.approach(thirty, 1, 0.0025, 1 / 30);
    let sixty = 0;
    for (let i = 0; i < 60; i++) sixty = KapaMotion.approach(sixty, 1, 0.0025, 1 / 60);
    assert.ok(Math.abs(thirty - sixty) < 1e-9 && Math.abs(thirty - 0.9975) < 1e-9);

    const far = KapaMotion.appetite(1000, 150);
    const middle = KapaMotion.appetite(75, 150);
    const over = KapaMotion.appetite(0, 150);
    assert.ok(far > 0 && far < middle && middle < over && over === 1);

    for (const reaction of ['nod', 'gulp', 'hop']) {
        assert.equal(KapaMotion.kick(reaction, KapaMotion.duration(reaction)), null, `${reaction} ends`);
        const near = KapaMotion.kick(reaction, KapaMotion.duration(reaction) - 0.001);
        assert.ok(Math.abs(near.sx - 1) < 0.02 && Math.abs(near.sy - 1) < 0.02 && Math.abs(near.dy) < 0.1, `${reaction} lands at rest`);
    }
    assert.equal(KapaMotion.boop(KapaMotion.boopLength), null);
    assert.equal(KapaMotion.shake(KapaMotion.shakeLength), null);

    assert.equal(KapaMotion.gulp(0).file, 0);
    assert.equal(KapaMotion.gulp(0.33).file, null);
    assert.equal(KapaMotion.gulp(KapaMotion.gulpLength), null);
});

test('the pose from the card, as the Rust reads it', () => {
    for (const {view, expression} of fixture.moods) assert.equal(capacityMood(view), expression, `${view.state} ${view.headline}`);
    for (const {views, focus} of fixture.focus) assert.deepEqual(capacityFocus(views), focus);
    assert.equal(capacityFocus([]), null, 'no cards, no Kapa');
    assert.ok(urgency('worried') < urgency('waiting') && urgency('rest') === 5);
    assert.equal(musicMood(true), 'music');
    assert.equal(musicMood(false), 'paused');
});

// MARK: - The drawing, with a recording context

/** A Cairo-style context that remembers every call and checks the numbers are real. */
function recorder() {
    const calls = [];
    const cr = new Proxy({}, {
        get(_t, name) {
            if (name === 'calls') return calls;
            return (...args) => {
                for (const a of args.flat(2)) {
                    if (typeof a === 'number') assert.ok(Number.isFinite(a), `${String(name)} was given ${a}`);
                }
                calls.push([name, ...args]);
            };
        },
    });
    return cr;
}

const count = (cr, name) => cr.calls.filter(c => c[0] === name).length;

function balanced(cr) {
    let depth = 0;
    for (const [name] of cr.calls) {
        if (name === 'save') depth++;
        if (name === 'restore') assert.ok(--depth >= 0, 'restore without a save');
    }
    assert.equal(depth, 0, 'a save was never restored');
}

const SIZES = [12, 17, 26, 30, 31.9, 32, 64, 146];

test('every pose at every size draws, with saves balanced and no NaN anywhere', () => {
    for (const expression of EXPRESSIONS) {
        for (const size of SIZES) {
            const cr = recorder();
            drawKapa(cr, null, {expression, size});
            balanced(cr);
            assert.ok(count(cr, 'fill') >= 3, `${expression}@${size} fills at least the shadow, the body and its shine`);
            assert.ok(count(cr, 'setSourceRadial') === 1, 'the body has its gradient, once');
            assert.ok(count(cr, 'curveTo') > 10, `${expression}@${size} has curves`);
        }
    }
});

test('a pose shows its parts: headphones, blush, badge, brows', () => {
    const draw = expression => {
        const cr = recorder();
        drawKapa(cr, null, {expression, size: 64});
        return cr;
    };
    const colours = cr => cr.calls.filter(c => c[0] === 'setSourceRGBA').map(c => c.slice(1, 4).map(v => Math.round(v * 255)).join());
    assert.ok(colours(draw('music')).includes('46,50,54'), 'music has its headphones (0x2E3236)');
    assert.ok(!colours(draw('rest')).includes('46,50,54'));
    assert.ok(count(draw('worried'), 'stroke') > count(draw('rest'), 'stroke'), 'worried adds brows and a sign');
    assert.ok(colours(draw('received')).includes('255,143,163'), 'received blushes (0xFF8FA3)');
    assert.ok(colours(draw('received')).includes('52,199,89'), 'and has its green tick (0x34C759)');
    assert.ok(!colours(draw('rest')).includes('255,143,163'));
    const dashed = draw('stale').calls.filter(c => c[0] === 'setDash' && c[1].length > 0);
    assert.equal(dashed.length, 1, 'the stale clock is dashed, once');
});

test('showsBadge off and an outline: no sign, and a ring round the body', () => {
    const plain = recorder();
    drawKapa(plain, null, {expression: 'worried', size: 64});
    const bare = recorder();
    drawKapa(bare, null, {expression: 'worried', size: 64, showsBadge: false});
    assert.ok(count(bare, 'fill') < count(plain, 'fill'), 'the alert disc is gone');

    const ringed = recorder();
    drawKapa(ringed, null, {expression: 'rest', size: 64, outline: [1, 0, 0, 1]});
    const ring = ringed.calls.find((c, i, all) => c[0] === 'setLineWidth' && c[1] === 6 && all[i - 1][0] === 'setSourceRGBA');
    assert.ok(ring, 'the ring is six units wide');
});

test('a mini Kapa has bolder strokes: under 32 the lines are half as thick again', () => {
    const widths = size => {
        const cr = recorder();
        drawKapa(cr, null, {expression: 'happy' in {} ? 'rest' : 'worried', size});
        return cr.calls.filter(c => c[0] === 'setLineWidth').map(c => c[1]);
    };
    const small = widths(26);
    const large = widths(64);
    assert.ok(small.some(w => w === 3) && large.some(w => w === 2), 'a brow is 2, boosted 3');
});

// MARK: - The engine

const rng = (...values) => {
    let i = 0;
    return () => values[i++ % values.length];
};

test('a Kapa never moved is drawn exactly as posed', () => {
    const engine = new KapaEngine({random: rng(0.5)});
    engine.step(0, {expression: 'curious', size: 64, moving: false});
    assert.equal(engine._yaw, 0.12);
    assert.equal(engine._pitch, 0.12);
    assert.equal(engine.isMoving(0), false, 'nothing to wake for');
    const puzzled = new KapaEngine();
    puzzled.step(0, {expression: 'puzzled', size: 64, moving: false});
    assert.equal(puzzled._tilt, -4);
});

test('a new pose arrives inside a blink, never a melt', () => {
    const engine = new KapaEngine({random: rng(0.5)});
    engine.step(0, {expression: 'rest', size: 64});
    assert.equal(engine.expression, 'rest');
    engine.step(1, {expression: 'worried', size: 64});
    assert.equal(engine.expression, 'rest', 'the old face stays while the lids close');
    assert.ok(engine._swapping);
    engine.step(1.03, {expression: 'worried', size: 64});
    assert.equal(engine.expression, 'rest', 'still, with the lids half down');
    engine.step(1.07, {expression: 'worried', size: 64}); // the lids are shut: the face changes behind them
    assert.equal(engine.expression, 'worried', 'and the new one is there when they open');
    assert.ok(!engine._swapping);
});

test('a drop is eaten once: the identity changing starts the gulp, on the engine\'s own clock', () => {
    const engine = new KapaEngine({random: rng(0.5)});
    const inputs = {expression: 'dropReady', size: 98};
    engine.step(10, inputs);
    // Epoch ms, as the Shelf's view has it: nothing like the engine's clock.
    const dropped = 1_760_000_000_000;
    engine.step(10.1, {...inputs, swallowedAt: dropped});
    assert.equal(engine._gulpAt, 10.1, 'started now, by the clock it is stepped on');
    for (let t = 10.1; t < 12; t += 1 / 30) engine.step(t, {...inputs, swallowedAt: dropped});
    assert.equal(engine._gulpAt, null, 'eaten once: the same drop every frame is not eaten again');
    engine.step(12, {...inputs, swallowedAt: new Date(dropped)});
    assert.equal(engine._gulpAt, null, 'nor the same drop as a Date');
    engine.step(12.1, {...inputs, swallowedAt: dropped + 5000});
    assert.equal(engine._gulpAt, 12.1, 'the next drop is');

    // Dropped while held still, it is noted and not eaten later.
    const still = new KapaEngine({random: rng(0.5)});
    still.step(0, {...inputs, moving: false, swallowedAt: dropped});
    still.step(0.1, {...inputs, swallowedAt: dropped});
    assert.equal(still._gulpAt, null);

    for (const none of [null, undefined, NaN]) {
        const fresh = new KapaEngine({random: rng(0.5)});
        fresh.step(0, inputs);
        fresh.step(0.1, {...inputs, swallowedAt: none});
        assert.equal(fresh._gulpAt, null, `${none} is no drop`);
    }
});

test('a dragged file is reached for over three of the size Kapa is stepped at, not shown at', () => {
    const engine = new KapaEngine({random: rng(0.5)});
    engine.frame = {x: 0, y: 0, width: 34, height: 34};
    engine.dragPoint = () => ({x: 17 + 147, y: 17});
    for (let t = 0; t < 3; t += 1 / 30) engine.step(t, {expression: 'dropReady', size: 98});
    assert.ok(Math.abs(engine._mouthTarget - KapaMotion.appetite(147, 294)) < 1e-12, 'reach 3 × 98');
    const cr = recorder();
    drawKapa(cr, null, {expression: 'dropReady', size: 98, drawnAt: 34, t: 3, engine});
    balanced(cr);
    assert.deepEqual(cr.calls.find(c => c[0] === 'scale'), ['scale', 34 / 98, 34 / 98], 'shown at 34, scaled');
    assert.ok(!cr.calls.some(c => c[0] === 'setLineWidth' && c[1] === 3), 'and not made bolder as a mini');
    const drawn = recorder();
    engine.draw(drawn);
    assert.deepEqual(drawn.calls.find(c => c[0] === 'scale'), ['scale', 0.98, 0.98], 'drawn at the size stepped at by default');
});

test('a drop is eaten: the gulp starts, the file is drawn going in, sparkles come after', () => {
    const engine = new KapaEngine({random: rng(0.5)});
    const inputs = {expression: 'dropReady', size: 64};
    engine.step(0, inputs);
    engine.step(0.1, {...inputs, swallowedAt: 0.1});
    assert.equal(engine._gulpAt, 0.1);
    engine.step(0.2, {...inputs, swallowedAt: 0.1});
    const cr = recorder();
    engine.draw(cr, {size: 64});
    balanced(cr);
    const fileFills = cr.calls.filter(c => c[0] === 'setSourceRGBA' && c[1] === 0xF2 / 255).length;
    assert.ok(fileFills >= 1, 'the file is drawn on its way in');
    engine.step(0.1 + KapaMotion.gulpLength + 0.01, {...inputs, swallowedAt: 0.1});
    assert.equal(engine._gulpAt, null, 'over');
    assert.ok(engine._particles.some(p => p.kind === 'sparkle'), 'and pleased with it');
});

test('the same random draws and the same times draw the same Kapa', () => {
    const run = () => {
        const engine = new KapaEngine({random: rng(0.1, 0.9, 0.3, 0.6)});
        const cr = recorder();
        for (let t = 0; t < 3; t += 1 / 30) engine.step(t, {expression: 'music', size: 64});
        engine.draw(cr, {size: 64});
        return JSON.stringify(cr.calls);
    };
    assert.equal(run(), run());
});

test('the music nods: the body dips with the beat', () => {
    const engine = new KapaEngine({random: rng(0.5)});
    engine.step(0, {expression: 'music', size: 64});
    for (let t = 1 / 30; t < 0.6; t += 1 / 30) engine.step(t, {expression: 'music', size: 64});
    const expected = KapaMotion.bob(0.6 - (0.6 % (1 / 30)));
    assert.ok(Math.abs(engine._dy - expected.dy) < 0.5);
    assert.ok(engine._particles.some(p => p.kind === 'note'), 'a note floats off');
});

test('how far above her square she reaches: nothing at rest, a note the higher the longer it floats, until it is gone', () => {
    const resting = new KapaEngine({random: rng(0.5)});
    resting.step(0, {expression: 'rest', size: 32});
    assert.equal(resting.reach(10), 0, 'her body and badge keep within the square');
    const engine = new KapaEngine({random: rng(0.5)});
    for (let t = 0; t < 0.6; t += 1 / 30) engine.step(t, {expression: 'music', size: 32});
    const note = engine._particles.find(p => p.kind === 'note');
    assert.ok(note);
    const end = note.born + note.life;
    assert.ok(engine.reach(note.born + 0.2) < engine.reach(note.born + 1), 'it rises');
    // Its stem's top, grown by half as it fades out, at the last moment it is drawn.
    assert.ok(Math.abs(engine.reach(end) - (note.life * 22 + 15 * 1.4 - note.y)) < 1e-9, 'at its highest as it goes out');
    assert.equal(engine.reach(end + 5), engine.reach(end), 'and no higher once gone');
    // A drop of sweat falls: it is highest as it starts.
    engine._particles = [{kind: 'sweat', born: 1, life: 1.5, x: 78, y: 40, drift: 0}];
    assert.equal(engine.reach(3), 0);
});

test('the pointer over Kapa draws a nod and, left there, a heart', () => {
    const engine = new KapaEngine({random: rng(0.5)});
    engine.step(0, {expression: 'rest', size: 64});
    engine.hover = {x: 40, y: 20};
    engine.step(0.1, {expression: 'rest', size: 64});
    assert.equal(engine._reaction.kind, 'nod');
    assert.ok(engine._yaw === 0 || engine._yaw < 0.5);
    for (let t = 0.2; t < 2.5; t += 1 / 30) engine.step(t, {expression: 'rest', size: 64});
    assert.ok(engine._pleasedUntil > 0, 'pleased');
    assert.ok(engine._particles.some(p => p.kind === 'heart'));
    assert.equal(engine.isMoving(2.5), true, 'moving while the pointer is there');
});

test('a tap boops it', () => {
    const engine = new KapaEngine({random: rng(0.5)});
    engine.step(5, {expression: 'rest', size: 64});
    engine.boop();
    const cr = recorder();
    engine.step(5.1, {expression: 'rest', size: 64});
    engine.draw(cr, {size: 64});
    assert.ok(engine.isMoving(5.1));
    balanced(cr);
});

test('Kapa rests between its blinks: the next frame is the next thing due, not 1/30 s on', () => {
    // A blink every 2.2 + 3.2 × 0.9 = 5.08 s, never twice; a glance every
    // 2.5 + 3.5 × 0.9 = 5.65 s, to a look of its own.
    const engine = new KapaEngine({random: rng(0.9)});
    const inputs = {expression: 'rest', size: 64};
    let t = 0;
    for (; t < 1.5; t += 1 / 30) engine.step(t, inputs);
    assert.equal(engine.isMoving(t), false, 'the first blink and glance are over, and it is there');
    const next = engine.nextFrame(t);
    assert.ok(next > t + 1, `it sleeps until the next blink: ${next} at ${t}`);
    assert.ok(Math.abs(next - Math.min(engine._nextBlink, engine._nextWander)) < 1e-9, 'which is the blink or the glance due');
    assert.ok(Math.abs(next - 5.08) < 1e-9, 'the blink, here, at 5.08 s');

    // Worried: its sweat drop, every 2.6 s, is due before the blink.
    const worried = new KapaEngine({random: rng(0.9)});
    for (t = 0; t < 2.5; t += 1 / 30) worried.step(t, {expression: 'worried', size: 64});
    assert.equal(worried.isMoving(t), false);
    assert.ok(Math.abs(worried.nextFrame(t) - 2.6) < 1e-9, 'the next drop of sweat');
});

test('a Kapa that is not running is drawn once and not again: off its page, under Reduce Motion', () => {
    assert.equal(new KapaEngine().nextFrame(0), Infinity, 'never stepped, nothing to draw for');
    const held = new KapaEngine({random: rng(0.5)});
    held.step(0, {expression: 'music', size: 64, moving: false});
    assert.equal(held.isMoving(0), false);
    assert.equal(held.nextFrame(0), Infinity, 'even music, which always moves, holds still');
    assert.equal(held._particles.length, 0, 'no notes float off');
    assert.equal(held._dy, 0, 'drawn as posed, not mid-nod');
    const cr = recorder();
    held.draw(cr, {size: 64});
    balanced(cr);
    assert.ok(count(cr, 'fill') >= 3, 'and it is drawn');

    // Running again, it wakes; held again, it rests where it was.
    held.step(1, {expression: 'music', size: 64});
    assert.equal(held.nextFrame(1), 1 + 1 / 30);
    held.step(1.1, {expression: 'music', size: 64, moving: false});
    assert.equal(held.nextFrame(1.1), Infinity);

    const reduced = recorder();
    drawKapa(reduced, null, {expression: 'listening', size: 64, isAnimated: false, level: 1});
    balanced(reduced);
});

test('a Kapa told to hold still draws no particles and leaves its eyes open', () => {
    const engine = new KapaEngine({random: rng(0.5)});
    for (let t = 0; t < 2; t += 1 / 30) engine.step(t, {expression: 'music', size: 64});
    assert.ok(engine._particles.length > 0);
    engine.step(2.1, {expression: 'music', size: 64, moving: false});
    assert.equal(engine._particles.length, 0);
    assert.equal(KapaMotion.lid(2.1 - engine._blinkAt), 1);
});

test('rounded corners are Apple\'s continuous ones, held to half the shorter side', () => {
    const path = (badge) => {
        const cr = recorder();
        drawBadge(cr, badge, 1);
        return cr.calls;
    };
    // The clipboard's board: 17 × 21, radius 3 — room for the whole continuous corner.
    const calls = path('clipboard');
    const start = calls.find(c => c[0] === 'moveTo');
    assert.ok(Math.abs(start[1] - (78 + 3 * 1.52866483)) < 1e-6 && start[2] === 8, 'the curve begins 1.53 radii from the corner');
    const points = [];
    for (const c of calls) {
        if (c[0] === 'moveTo' || c[0] === 'lineTo') points.push(c.slice(1));
        if (c[0] === 'curveTo') points.push(c.slice(1, 3), c.slice(3, 5), c.slice(5, 7));
        if (c[0] === 'fill') break;
    }
    for (const [x, y] of points) assert.ok(x >= 78 - 1e-9 && x <= 95 + 1e-9 && y >= 8 - 1e-9 && y <= 29 + 1e-9, `inside the board: ${x}, ${y}`);
    assert.ok(points.some(([x, y]) => Math.abs(x - 95) < 1e-9 && Math.abs(y - 8 - 3 * 1.52866483) < 1e-6), 'and ends 1.53 radii down the side');

    // An earcup: 12 wide with a radius of 5 cannot fit the whole corner, so it
    // is blended towards a circle until it meets the middle of the side.
    const cups = recorder();
    drawHeadphones(cups);
    const cup = cups.calls.filter(c => c[0] === 'moveTo')[1];
    assert.ok(Math.abs(cup[1] - 16) < 1e-9 && cup[2] === 48, `the corner reaches the middle of the top: ${cup}`);
    const xs = [];
    let seen = 0;
    for (const c of cups.calls) {
        if (c[0] === 'moveTo') seen++;
        if (seen === 2 && c[0] === 'curveTo') xs.push(c[1], c[3], c[5]);
    }
    assert.ok(Math.min(...xs) >= 10 - 1e-9 && Math.max(...xs) <= 22 + 1e-9, 'and stays inside the cup');
});

// MARK: - The adapters

test('the canvas wrapper does what Kapa asks of it: gradients, dash, transform, save', () => {
    const calls = [];
    const ctx = new Proxy({}, {
        get: (_t, name) => (...a) => {
            calls.push([name, ...a]);
            if (name === 'createRadialGradient' || name === 'createLinearGradient')
                return {addColorStop: (...s) => calls.push(['addColorStop', ...s])};
            return undefined;
        },
        set: (_t, name, value) => { calls.push(['=' + String(name), value]); return true; },
    });
    const cr = new CairoCanvas(ctx);
    cr.setSourceRadial(36, 30, 0, 36, 30, 85, [[0, 1, 1, 1, 1], [1, 0, 0, 0, 0.5]]);
    cr.setSourceLinear(0, 0, 1, 1, [[0, 1, 0, 0]]);
    cr.setDash([2, 1], 0);
    cr.setLineJoin(1);
    cr.scale(2, 3);
    cr.rotate(1);
    cr.save();
    cr.restore();
    assert.deepEqual(calls.find(c => c[0] === 'createRadialGradient'), ['createRadialGradient', 36, 30, 0, 36, 30, 85]);
    assert.deepEqual(calls.filter(c => c[0] === 'addColorStop'), [
        ['addColorStop', 0, 'rgba(255,255,255,1)'],
        ['addColorStop', 1, 'rgba(0,0,0,0.5)'],
        ['addColorStop', 0, 'rgba(255,0,0,1)'],
    ]);
    assert.deepEqual(calls.find(c => c[0] === 'setLineDash'), ['setLineDash', [2, 1]]);
    assert.deepEqual(calls.find(c => c[0] === '=lineJoin'), ['=lineJoin', 'round']);
    assert.ok(calls.some(c => c[0] === 'scale' && c[1] === 2 && c[2] === 3) && calls.some(c => c[0] === 'rotate'));
});

test('Kapa draws through a canvas wrapper end to end', () => {
    const ctx = new Proxy({}, {
        get: (_t, name) => (...a) => (/^create/.test(String(name)) ? {addColorStop() {}} : undefined),
        set: () => true,
    });
    for (const expression of EXPRESSIONS) drawKapa(new CairoCanvas(ctx), null, {expression, size: 64});
});

test('the GJS wrapper reaches Cairo with the same meaning, gradients through Cairo\'s own classes', () => {
    const calls = [];
    const cr = new Proxy({$dispose() { calls.push(['$dispose']); }}, {
        get: (target, name) => target[name] ?? ((...a) => calls.push([name, ...a])),
    });
    class Gradient {
        constructor(...args) { this.args = args; this.stops = []; }
        addColorStopRGBA(...s) { this.stops.push(s); }
    }
    const Cairo = {LinearGradient: class extends Gradient {}, RadialGradient: class extends Gradient {}};
    const wrapped = new CairoGjs(cr, Cairo);
    wrapped.setSourceRadial(36, 30, 0, 36, 30, 85, [[0, 1, 0, 0, 1], [1, 0, 0, 1]]);
    const set = calls.find(c => c[0] === 'setSource');
    assert.ok(set[1] instanceof Cairo.RadialGradient);
    assert.deepEqual(set[1].args, [36, 30, 0, 36, 30, 85]);
    assert.deepEqual(set[1].stops, [[0, 1, 0, 0, 1], [1, 0, 0, 1, 1]], 'alpha defaults to 1');
    wrapped.setDash([2, 1]);
    assert.deepEqual(calls.at(-1), ['setDash', [2, 1], 0]);
    for (const expression of EXPRESSIONS) {
        const target = new CairoGjs(new Proxy({$dispose() {}}, {get: (t, n) => t[n] ?? (() => {})}), Cairo);
        drawKapa(target, null, {expression, size: 64});
    }
    wrapped.dispose();
    assert.deepEqual(calls.at(-1), ['$dispose']);
});
