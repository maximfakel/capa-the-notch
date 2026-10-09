// Run with: node --test linux/js/test/*.test.js
// The Music Module's layout against the numbers the Swift measures, the
// progress bar's rules against `MusicProgress` in Rust, and the page and row
// drawn into a recording context.

import assert from 'node:assert/strict';
import test from 'node:test';

import {Gfx, RecordingText} from '../ui/gfx.js';
import {SurfaceScene} from '../ui/scene.js';
import {deriveModel} from '../ui/model.js';
import {EQUALIZER, MusicType, controlsWidth, idleLayout, pageLayout, rowLayout} from '../ui/modules/music-layout.js';
import {Bars, easeInEaseOut} from '../ui/modules/music-parts.js';
import {GIVE_UP_AFTER, Progress, clockText, trackPosition} from '../ui/modules/music-progress.js';
import {PRESSED_OPACITY} from '../ui/widgets.js';

const blackHole = () => new Proxy({}, {get: () => () => {}});

const near = (a, b, why = '') => assert.ok(Math.abs(a - b) < 1e-9, `${a} != ${b} ${why}`);

// The page reads the machine's clock, so the test's track is reported now.
const T0 = Date.now();
const track = (extra = {}) => ({
    title: 'Mad Technology', artist: 'CZARFACE, Frankie Pulitzer, Method Man', album: null, player: 'Chrome', isPlaying: true,
    duration: 224, elapsed: 46, elapsedAt: new Date(T0).toISOString(), rate: 1, ...extra,
});

// MARK: - The layout

test('the row is 54 tall: six under the strip, the artwork 34, fourteen to the edge', () => {
    assert.equal(MusicType.rowHeight, 6 + MusicType.rowArtwork + 14);
    assert.equal(MusicType.pageArtwork, 146);
});

test('the compact row: eighteen in, the artwork and its text, the controls and Kapa or the bars at the right', () => {
    const row = rowLayout(370, 100, 38, {kapa: false});
    assert.deepEqual(row.artwork, {x: 118, y: 44, size: 34});
    near(row.text.x, 118 + 34 + 8);
    // The right group: controls, twenty, the bars' 32; it ends eighteen from the edge.
    near(row.controls.x + controls(10, 14) + 20 + 32, 100 + 370 - 18);
    near(row.text.x + row.text.width + 20, row.controls.x);
    assert.equal(row.effect.height, 30);
    near(row.effect.y, 44 + 2, 'a 30-tall bar in the 34 frame');
    const kapa = rowLayout(370, 100, 38, {kapa: true});
    assert.equal(kapa.effect.size, 32);
    near(kapa.effect.y, 44 + 1);
});

function controls(small, large) {
    return controlsWidth(small, large);
}

test('the page: the artwork 146 from the page top plus six, the column 121 tall centred against it', () => {
    const page = pageLayout(560, 0, 38, {kapa: true});
    assert.deepEqual(page.artwork, {x: 18, y: 44, size: 146});
    near(page.column.x, 18 + 146 + 20);
    near(page.column.x + page.column.width, 560 - 18);
    near(page.column.top, 44 + (146 - 121) / 2);
    // 34, twenty, the bar 4 + 7 + 14, twenty, 22 = 121
    near(page.progress.y - page.column.top, 34 + 20);
    near(page.controls.top - page.column.top, 34 + 20 + 25 + 20);
    near(page.controls.top + 22 - page.column.top, 121);
    assert.equal(page.effect.size, 40);
    assert.equal(pageLayout(560, 0, 38, {kapa: false}).effect.height, 34);
    near(page.volume.button.x + 18 + 8, page.volume.barX, 'the speaker, eight, the bar');
    near(page.volume.barX + 88, page.column.x + page.column.width, 'right-aligned');
});

test('the idle page keeps the page height and the same column', () => {
    const idle = idleLayout(560, 0, 38, {remembered: null});
    assert.equal(idle.artwork.size, 146);
    assert.equal(idle.column.height, 121);
});

// MARK: - The progress bar (MusicProgress)

test('the clock is mm:ss, and never negative', () => {
    assert.equal(clockText(46), '00:46');
    assert.equal(clockText(224), '03:44');
    assert.equal(clockText(-3), '00:00');
    assert.equal(clockText(3599.9), '59:59');
});

test('a position moves on at the rate, from when it was reported, and stays inside the track', () => {
    const pos = (at, extra) => trackPosition(track(extra), T0 + at * 1000);
    near(pos(10), 56);
    near(pos(0), 46);
    near(pos(10, {rate: 0}), 46, 'paused does not move on');
    near(pos(500), 224, 'never past the end');
    near(pos(10, {elapsed: -5}), 5, 'nor before the start');
    assert.equal(trackPosition({title: 'x', isPlaying: true}, T0), null);
});

test('dragging shows where the finger is, and letting go sends the seek', () => {
    const p = new Progress();
    const tr = track();
    p.drag(0.5, tr);
    near(p.view(tr, T0).position, 112);
    near(p.view(tr, T0).fraction, 0.5);
    assert.equal(p.endDrag(tr, T0), 112);
    assert.equal(p.endDrag(tr, T0), null, 'once');
});

test('after the seek the bar stays where it was let go, moving on at the rate, until the reading lands', () => {
    const p = new Progress();
    const tr = track();
    p.drag(0.5, tr);
    p.endDrag(tr, T0);
    near(p.view(tr, T0 + 1000).position, 113, 'not springing back to the old reading');
    // The track reported near where it should be settles it.
    const landed = track({elapsed: 113, elapsedAt: new Date(T0 + 1500).toISOString()});
    p.view(landed, T0 + 1600);
    assert.equal(p.sought, null);
});

test('a seek that is never answered gives the bar back after three seconds', () => {
    const p = new Progress();
    const tr = track();
    p.drag(0.9, tr);
    p.endDrag(tr, T0);
    assert.notEqual(p.sought, null);
    p.view(tr, T0 + GIVE_UP_AFTER - 1);
    assert.notEqual(p.sought, null);
    near(p.view(tr, T0 + GIVE_UP_AFTER).position, 46 + 3, 'back to the reading');
    assert.equal(p.sought, null);
});

test('a track with no duration cannot be sought', () => {
    const p = new Progress();
    p.drag(0.5, track({duration: null}));
    assert.equal(p.dragged, null);
});

test('only a new reading settles a seek, and only one near where the track should be; a new track does not', () => {
    const p = new Progress();
    const tr = track();
    p.drag(0.5, tr);
    p.endDrag(tr, T0);
    // The same reading again, however long after, is not an answer.
    p.view(track({title: 'Zima'}), T0 + 10);
    assert.notEqual(p.sought, null, 'what was sought outlives a change of track, as the Swift\'s @State does');
    // A new reading far from the target does not settle it…
    p.view(track({elapsed: 60, elapsedAt: new Date(T0 + 20).toISOString()}), T0 + 30);
    assert.notEqual(p.sought, null);
    // …and one near it does, at once: there is no floor.
    p.view(track({elapsed: 112, elapsedAt: new Date(T0 + 40).toISOString()}), T0 + 50);
    assert.equal(p.sought, null);
});

test('any change to the track is a reading that may settle a seek, not only a new moment', () => {
    const p = new Progress();
    const tr = track();
    p.drag(0.5, tr);
    p.endDrag(tr, T0);
    // A player that moves its position without a new timestamp still answers (`.onChange(of: track)`).
    p.view(track({elapsed: 112}), T0 + 50);
    assert.equal(p.sought, null);
});

test('the bar is drawn for its beat, not for the moment of the frame', () => {
    const p = new Progress();
    near(p.view(track(), T0 + 1900, T0 + 1000).position, 47, 'the last beat, a second in');
});

// MARK: - The bars

test('seven bars, two wide five apart, rest at a four-point dash and play between a third and the top', () => {
    assert.equal(EQUALIZER.width, 7 * 2 + 6 * 3);
    const bars = new Bars(30, 9);
    bars.step(0, {playing: false});
    bars.step(1, {playing: false});
    for (const s of bars.scales(2)) near(s, 4 / 30);
    let moving = false;
    for (let now = 3; now < 12; now += 0.3) {
        moving = bars.step(now, {playing: true});
        for (const s of bars.to) assert.ok(s >= 0.3 && s <= 1, `${s}`);
    }
    assert.ok(moving);
    assert.ok(new Set(bars.to.map(s => s.toFixed(4))).size > 3, 'every bar has a height of its own');
    const still = new Bars(30, 9);
    still.step(0, {playing: true, still: true});
    assert.equal(still.step(5, {playing: true, still: true}), false, 'under Reduce Motion they hold still');
});

test('playing again within a beat of a pause, the bars rise at once', () => {
    const bars = new Bars(30, 9);
    bars.step(0, {playing: true});
    bars.step(0.3, {playing: true});
    bars.step(0.4, {playing: false});
    const sunk = bars.to.slice();
    bars.step(0.5, {playing: true});
    assert.equal(bars.begin, 0.5, 'not held until the pause\'s beat is over');
    assert.notDeepEqual(bars.to, sunk);
    for (const s of bars.to) assert.ok(s >= 0.3 && s <= 1, `${s}`);
});

test('the ease runs slow, fast, slow', () => {
    near(easeInEaseOut(0), 0);
    assert.ok(Math.abs(easeInEaseOut(1) - 1) < 1e-6);
    assert.ok(Math.abs(easeInEaseOut(0.5) - 0.5) < 1e-3);
    assert.ok(easeInEaseOut(0.1) < 0.1 && easeInEaseOut(0.9) > 0.9);
});

// MARK: - The scene

function sceneWith(music, {showsKapa = true} = {}) {
    const calls = [];
    const scene = new SurfaceScene({barHeight: 38, notchWidth: 0}, {
        call: (module, method, args) => {
            calls.push([module, method, args]);
            return Promise.resolve(null);
        },
        decodeImage: () => Promise.resolve(null),
    });
    const state = {
        providers: [], pages: ['capacity', 'music'], modules: {music}, showsKapa,
    };
    scene.setModel(deriveModel(state));
    scene.calls = calls;
    return scene;
}

function draw(scene, width = 608, height = 320) {
    const text = new RecordingText();
    scene.tick(scene.now + 0.016);
    scene.draw(new Gfx(blackHole(), text), {width, height});
    return text;
}

const playingState = (extra = {}) => ({
    on: true, unreadable: false, shown: track(), loaded: track(), remembered: null, volume: null, serverNow: T0, ...extra,
});

test('closed, a playing track is a row under the strip, 54 tall, as wide as the strip', () => {
    const scene = sceneWith(playingState());
    assert.equal(scene.compactSize.height, 38 + 54);
    assert.equal(scene.compactSize.width, scene.compactWidth);
    const text = draw(scene);
    assert.ok(text.calls.some(c => c.str === 'Mad Technology' && c.font.size === 15));
    assert.ok(text.calls.some(c => c.str.startsWith('CZARFACE') && c.font.size === 11));
    for (const id of ['music-row:prev', 'music-row:toggle', 'music-row:next'])
        assert.ok(scene.hits.some(h => h.id === id), id);
});

test('over a fullscreen application there is no row; nor with nothing shown', () => {
    const scene = sceneWith(playingState());
    scene.fullscreen = true;
    assert.equal(scene.compactSize.height, 38);
    const nothing = sceneWith(playingState({shown: null}));
    assert.equal(nothing.compactSize.height, 38);
});

test('the row\'s buttons call the module', () => {
    const scene = sceneWith(playingState());
    draw(scene);
    for (const [id, expected] of [['prev', 'previous'], ['toggle', 'togglePlayPause'], ['next', 'next']]) {
        const hit = scene.hits.find(h => h.id === `music-row:${id}`);
        assert.equal(hit.cursor, undefined, 'a plain button: the pointer stays an arrow');
        // A button acts when it is let go over (`.buttonStyle(.plain)`).
        scene.press(hit.x + hit.w / 2, hit.y + hit.h / 2);
        scene.release(hit.x + hit.w / 2, hit.y + hit.h / 2);
        assert.deepEqual(scene.calls.at(-1), ['music', 'command', {command: expected}]);
    }
});

/** The fades the groups were laid down at in one frame. */
function groupFades(scene, width = 608, height = 320) {
    const g = new Gfx(blackHole(), new RecordingText());
    const fades = [];
    const group = g.group.bind(g);
    g.group = (alpha, fn) => {
        fades.push(alpha);
        group(alpha, fn);
    };
    scene.tick(scene.now + 0.016);
    scene.draw(g, {width, height});
    return fades;
}

test('a transport or mute button held down is dimmed as one picture, and only while held', () => {
    const scene = sceneWith(playingState({volume: {level: 0.5, isMuted: false, shownLevel: 0.5, icon: 'wave2'}}));
    open(scene);
    draw(scene);
    const dimmed = fades => fades.filter(a => a === PRESSED_OPACITY).length;
    assert.equal(dimmed(groupFades(scene)), 0);
    for (const id of ['music:prev', 'music:toggle', 'music:next', 'music:mute']) {
        const hit = scene.hits.find(h => h.id === id);
        scene.press(hit.x + hit.w / 2, hit.y + hit.h / 2);
        assert.equal(dimmed(groupFades(scene)), 1, id);
        scene.release(hit.x + hit.w / 2, hit.y + hit.h / 2, {cancel: true});
        assert.equal(dimmed(groupFades(scene)), 0, `${id} let go`);
    }
});

test('the row\'s transport buttons dim while held too', () => {
    const scene = sceneWith(playingState());
    draw(scene);
    const hit = scene.hits.find(h => h.id === 'music-row:toggle');
    scene.press(hit.x + hit.w / 2, hit.y + hit.h / 2);
    assert.ok(groupFades(scene).includes(PRESSED_OPACITY));
});

function open(scene) {
    scene.pin();
    scene.select('music');
    for (let i = 0; i < 400; i++) scene.tick(i * 0.016);
}

test('open, the music page shows the title, the times and the controls', () => {
    const scene = sceneWith(playingState({volume: {level: 0.5, isMuted: false, shownLevel: 0.5, icon: 'wave2'}}));
    open(scene);
    const text = draw(scene);
    const said = text.calls.map(c => c.str);
    assert.ok(said.includes('Mad Technology'));
    assert.ok(said.includes('03:44'), 'the duration at the right');
    assert.ok(said.some(s => /^\d\d:\d\d$/.test(s) && s !== '03:44'), 'and the position at the left');
    for (const id of ['music:prev', 'music:toggle', 'music:next', 'music:progress', 'music:mute', 'music:volume'])
        assert.ok(scene.hits.some(h => h.id === id), id);
});

test('there is no volume bar until the level has been read', () => {
    const scene = sceneWith(playingState({volume: null}));
    open(scene);
    draw(scene);
    assert.ok(!scene.hits.some(h => h.id === 'music:volume' || h.id === 'music:mute'));
});

test('dragging the progress bar seeks to where it is let go', () => {
    const scene = sceneWith(playingState());
    open(scene);
    draw(scene);
    const bar = scene.hits.find(h => h.id === 'music:progress');
    const left = bar.x + 6, width = bar.w - 12;
    scene.press(left + width * 0.25, bar.y + 8);
    scene.setPointer({x: left + width * 0.5, y: bar.y + 8});
    scene.setPointer({x: left + width * 0.75, y: bar.y + 8});
    scene.release();
    const seek = scene.calls.filter(c => c[1] === 'command').at(-1);
    assert.equal(seek[2].command, 'seek');
    near(seek[2].to, 224 * 0.75);
});

test('dragging the volume bar sets the level, and the last place is always sent', () => {
    const scene = sceneWith(playingState({volume: {level: 0.5, isMuted: false, shownLevel: 0.5, icon: 'wave2'}}));
    open(scene);
    draw(scene);
    const bar = scene.hits.find(h => h.id === 'music:volume');
    const x0 = bar.x + 8;
    scene.press(x0 + 22, bar.y + 10);
    scene.setPointer({x: x0 + 44, y: bar.y + 10});
    scene.setPointer({x: x0 + 66, y: bar.y + 10});
    scene.release();
    const levels = scene.calls.filter(c => c[1] === 'volume.setLevel').map(c => c[2].level);
    near(levels.at(-1), 0.75);
    assert.ok(levels.every(l => l >= 0 && l <= 1));
});

test('the volume is watched while the surface is open with a track loaded, on whichever page', async () => {
    const scene = sceneWith(playingState());
    scene.modulesNeedFrames();
    const watches = () => scene.calls.filter(c => c[1] === 'volume.watch').map(c => c[2].on);
    assert.deepEqual(watches(), [], 'closed: nothing is asked of the audio system');
    scene.pin();
    scene.modulesNeedFrames();
    assert.deepEqual(watches(), [true], 'open on Capacity: a swipe towards the music page finds the level read');
    scene.select('music');
    scene.modulesNeedFrames();
    scene.select('capacity');
    scene.modulesNeedFrames();
    assert.deepEqual(watches(), [true], 'turning pages changes nothing');
    scene.collapse();
    scene.pinned = false;
    scene.modulesNeedFrames();
    assert.deepEqual(watches(), [true, false]);
    const idle = sceneWith(playingState({shown: null, loaded: null}));
    idle.pin();
    idle.modulesNeedFrames();
    assert.deepEqual(idle.calls.filter(c => c[1] === 'volume.watch'), [], 'nothing loaded: no bar to fill');
});

test('with nothing loaded the page says so, and shows the last track dimmed when there is one', () => {
    const none = sceneWith({on: true, shown: null, loaded: null, remembered: null, volume: null, serverNow: T0});
    open(none);
    const empty = draw(none).calls.map(c => c.str);
    assert.ok(empty.includes('Nothing playing'));
    assert.ok(empty.includes('Play a track in any player and it shows up here'));
    assert.ok(!none.hits.some(h => h.id.startsWith('music:')), 'no controls with nothing to act on');

    const ended = new Date(T0).toISOString();
    const some = sceneWith({on: true, shown: null, loaded: null, remembered: {track: track({isPlaying: false}), endedAt: ended}, volume: null, serverNow: T0});
    open(some);
    const said = draw(some).calls.map(c => c.str);
    assert.ok(said.includes('Mad Technology') && said.includes('Nothing playing'));
    assert.ok(said.some(s => s.startsWith('Played at ')), 'a bare id is no name: ' + said.join('|'));

    const named = sceneWith({on: true, shown: null, loaded: null, remembered: {track: track({isPlaying: false, playerName: 'Google Chrome'}), endedAt: ended}, volume: null, serverNow: T0});
    open(named);
    assert.ok(draw(named).calls.some(c => c.str.startsWith('Played in Google Chrome · ')));
});

test('without Kapa the bars stand where she would, and keep the frames coming while it plays', () => {
    const scene = sceneWith(playingState(), {showsKapa: false});
    near(scene.moduleFrameInterval(), 1 / 24, 'the bars move at 24 frames a second');
    assert.equal(scene.modulesNeedFrames(), false, 'not every frame');
    const paused = sceneWith(playingState({shown: track({isPlaying: false})}), {showsKapa: false});
    assert.equal(paused.moduleFrameInterval(), Infinity);
    // With Kapa, she asks for the frames herself.
    assert.equal(sceneWith(playingState()).moduleFrameInterval(), Infinity);
    // Over a fullscreen application the row is not there: nothing asks for frames.
    const fullscreen = sceneWith(playingState(), {showsKapa: false});
    fullscreen.fullscreen = true;
    assert.equal(fullscreen.moduleFrameInterval(), Infinity);
});

/** A context that writes down every call made of it, and does nothing. */
function recorder() {
    const calls = [];
    return {calls, cr: new Proxy({}, {get: (_t, name) => (...args) => { calls.push([name, ...args]); }})};
}

test('on the host\'s layer the bars are drawn there alone, where the surface drew them', () => {
    // Two surfaces alike, at rest and closed, a frame at the same moment: one draws its bars itself, one leaves them to the layer.
    const scenes = [false, true].map(layer => {
        const scene = sceneWith(playingState(), {showsKapa: false});
        scene.liveLayers = true;
        scene.tick(10);
        scene.rowLayer = layer && scene.rowLayerReady();
        return scene;
    });
    const [itself, layered] = scenes;
    assert.equal(itself.rowLayerReady(), true, 'closed, at rest, with bars: the layer may take them');
    assert.equal(layered.rowLayer, true);

    const drawn = scene => {
        const {calls, cr} = recorder();
        scene.draw(new Gfx(cr, new RecordingText()), {width: 608, height: 320});
        return calls;
    };
    const whole = drawn(itself), without = drawn(layered);
    const {calls: layerCalls, cr} = recorder();
    layered.drawRowLayer(new Gfx(cr, new RecordingText()), 304);

    // The surface's drawing with the bars taken out is the layered surface's, call for call.
    let at = 0;
    while (at < without.length && JSON.stringify(whole[at]) === JSON.stringify(without[at]))
        at++;
    const bars = whole.slice(at, at + whole.length - without.length);
    assert.deepEqual(whole.slice(at + bars.length), without.slice(at), 'nothing else is left out or moved');
    assert.equal(bars.filter(c => c[0] === 'fill').length, EQUALIZER.count, 'what is left out is the seven bars');
    assert.ok(bars.every(c => c[0] !== 'setSourceRGBA' || Math.abs(c[4] - EQUALIZER.alpha) < 1e-9), 'at their own strength');
    // The layer draws those same calls, in the shape's clip.
    assert.deepEqual(layerCalls.slice(-bars.length - 1, -1), bars, 'the layer draws the same bars, at the same places');
    assert.ok(layerCalls.some(c => c[0] === 'clip'), 'inside the shape, as the surface clips them');

    // The rectangle the host gives the layer holds every bar.
    const row = rowLayout(itself.compactWidth, 304 - itself.compactWidth / 2, 38, {kapa: false});
    assert.deepEqual(layered.rowLayerRect(304), {x: row.effect.x, y: row.effect.y, w: 32, h: 30});
    const xs = bars.filter(c => c[0] === 'translate').map(c => c[1]);
    assert.equal(xs.length, EQUALIZER.count);
    assert.ok(xs.every(x => x >= row.effect.x && x + EQUALIZER.barWidth <= row.effect.x + 32), xs.join(','));

    // The frames: the surface's drawing asks for none, the layer's for its next beat.
    assert.equal(layered.kapaDue, Infinity, 'the surface itself has nothing to draw again');
    assert.equal(layered.moduleFrameInterval(), Infinity, 'nor a beat for the surface');
    near(layered.layerDue, layered.now + 1 / 24, 'the layer\'s own next frame');
    near(itself.kapaDue, itself.now + 1 / 24, 'drawn by the surface, the surface asks as before');
    near(itself.moduleFrameInterval(), 1 / 24);
});

test('the layer is not used while anything else moves, nor without a row', () => {
    const scene = sceneWith(playingState(), {showsKapa: false});
    scene.liveLayers = true;
    scene.tick(10);
    assert.equal(scene.rowLayerReady(), true);
    scene.expand();
    scene.tick(10.016);
    assert.equal(scene.rowLayerReady(), false, 'opening');
    scene.collapse();
    scene.tick(10.032);
    assert.equal(scene.rowLayerReady(), false, 'closing: the shape and the row\'s fade are on their way');
    for (let t = 10.05; t < 13; t += 0.016)
        scene.tick(t);
    assert.equal(scene.rowLayerReady(), true, 'closed and still again');
    scene.setPointerNear(true);
    scene.tick(13.016);
    assert.equal(scene.rowLayerReady(), false, 'the shape growing to the pointer');
    scene.fullscreen = true;
    assert.equal(scene.rowLayerReady(), false, 'no row over a fullscreen application');
    const kapa = sceneWith(playingState());
    kapa.liveLayers = true;
    kapa.tick(10);
    assert.equal(kapa.rowLayerReady(), true, 'Kapa where the bars stand goes on it too');
    const host = sceneWith(playingState(), {showsKapa: false});
    host.tick(10);
    assert.equal(host.rowLayerReady(), false, 'a host without a layer draws them itself');
});

/** A seeded stand-in for `Math.random`, the same stream each time: Kapa's engines take theirs when made. */
function seeded(seed) {
    let x = seed;
    return () => {
        x = (x * 1103515245 + 12345) % 2147483648;
        return x / 2147483648;
    };
}

/**
 * A drawing's pictures of their own (`Gfx.isolated`) taken out of it: `parts`, by their
 * rectangle, the calls of each; `rest`, everything else.
 */
function pieces(calls) {
    const parts = new Map(), rest = [];
    for (let i = 0; i < calls.length; i++) {
        const isolated = calls[i][0] === 'save' && calls[i + 1]?.[0] === 'newPath' && calls[i + 2]?.[0] === 'rectangle'
            && calls[i + 3]?.[0] === 'clip' && calls[i + 4]?.[0] === 'pushGroup';
        if (!isolated) {
            rest.push(calls[i]);
            continue;
        }
        let depth = 0, end = i;
        for (; end < calls.length; end++) {
            depth += calls[end][0] === 'save' ? 1 : calls[end][0] === 'restore' ? -1 : 0;
            if (depth === 0)
                break;
        }
        parts.set(JSON.stringify(calls[i + 2].slice(1)), calls.slice(i, end + 1));
        i = end;
    }
    return {parts, rest};
}

test('the row\'s Kapa on the layer: drawn and stepped as the surface drew her, her tap kept by the surface', () => {
    // Two surfaces alike, each Kapa on the same random stream. One draws everything every
    // frame; the other as the host does with the layer: the surface on some frames (the
    // first, a wake, one with the layer off) and whenever it is asked for one, the layer on
    // every frame it is on.
    const make = () => {
        const scene = sceneWith(playingState());
        scene.liveLayers = true;
        return scene;
    };
    const itself = make(), layered = make();
    const drawWith = (scene, fn, seed) => {
        const {calls, cr} = recorder();
        const random = Math.random;
        if (seed)
            Math.random = seeded(seed);
        try {
            fn(new Gfx(cr, new RecordingText()));
        } finally {
            Math.random = random;
        }
        return calls;
    };
    const whole = (scene, seed) => drawWith(scene, g => scene.draw(g, {width: 608, height: 320}), seed);
    const layer = (scene, seed) => drawWith(scene, g => scene.drawRowLayer(g, 304), seed);

    // Her room in the row, in two: over the strip, and from where the row begins.
    const row = rowLayout(itself.compactWidth, 304 - itself.compactWidth / 2, 38, {kapa: true});
    const e = row.effect;
    const above = {x: e.x - e.size / 4, y: e.y - e.size / 2, w: e.size * 1.5, h: 38 - (e.y - e.size / 2)};
    const below = {x: above.x, y: 38, w: above.w, h: e.y + e.size * 1.25 - 38};
    const key = r => JSON.stringify([r.x, r.y, r.w, r.h]);
    const r = layered.rowLayerRect(304);
    assert.deepEqual(r, below, 'the layer\'s rectangle starts where the row does, under the top bar');

    // Frames at thirty a second for six seconds, with the surface drawn on these.
    const surfaceFrames = new Set([0, 17, 40, 41]);
    const layerOff = 40;
    let rest = null, over = 0, asked = 0;
    for (let i = 0; i < 180; i++) {
        const now = 10 + i / 30;
        // The host draws the surface when it asked for a frame (the part of her over the strip).
        const wanted = Number.isFinite(layered.kapaDue);
        itself.tick(now);
        layered.tick(now);
        const expected = pieces(whole(itself, i === 0 && 7));
        assert.equal(layered.rowLayerReady(), true);
        const surface = surfaceFrames.has(i) || wanted;
        if (surfaceFrames.has(i))
            layered.rowLayer = i !== layerOff;
        const main = surface ? pieces(whole(layered, i === 0 && 7)) : null;
        if (!layered.rowLayer) {
            // The layer off: the surface draws her itself, exactly as the other.
            assert.deepEqual(main, expected, `frame ${i}, the layer off`);
            assert.equal(layered.kapaDue, itself.kapaDue);
            continue;
        }
        if (main) {
            rest = main.rest;
            // Of her, the surface draws the part over the strip, as the other did, and only while there is one.
            assert.deepEqual(main.parts.get(key(above)), expected.parts.get(key(above)), `frame ${i}: over the strip`);
            assert.ok(!main.parts.has(key(below)), `frame ${i}: the rest is the layer's`);
            if (wanted && !surfaceFrames.has(i))
                asked++;
        } else if (expected.parts.has(key(above))) {
            // The other draws the part over the strip a little before anything is there;
            // the surface, asked, draws it from the next frame.
            const reach = itself.engines.get('music-row').reach(now);
            assert.ok(e.y - reach * e.size / 100 >= 38, `frame ${i}: something of hers over the strip, and the surface not drawn`);
        }
        if (expected.parts.has(key(above)))
            over++;
        assert.deepEqual(rest, expected.rest, `frame ${i}: nothing else left out or moved`);
        const drawn = pieces(layer(layered, i === 0 && 7));
        assert.deepEqual([...drawn.parts.keys()], [key(below)], `frame ${i}: the layer draws only the rest`);
        assert.deepEqual(drawn.parts.get(key(below)), expected.parts.get(key(below)), `frame ${i}: the layer draws her as the surface did`);
        // Her frames come to the layer, at the moment they came to the surface.
        assert.equal(layered.layerDue, itself.kapaDue, `frame ${i}`);
        if (expected.parts.has(key(above)))
            assert.ok(Number.isFinite(layered.kapaDue), `frame ${i}: the surface is asked for a frame, to draw what is over the strip`);
        if (main) {
            const tap = h => h.id === 'kapa:music-row';
            assert.deepEqual(layered.hits.filter(tap).map(({id, x, y, w, h}) => ({id, x, y, w, h})),
                itself.hits.filter(tap).map(({id, x, y, w, h}) => ({id, x, y, w, h})), 'her tap, on the surface');
            assert.equal(layered.hits.map(h => h.id).join(), itself.hits.map(h => h.id).join(), 'in the same order');
        }
    }
    assert.ok(over > 0 && asked > 0, `her notes rose over the strip (${over} frames), and the surface was asked to draw them (${asked})`);
    assert.ok(over < 90, `but not for most of the time: ${over} of 180`);

    // A tap on her, kept by the surface, boops the engine the layer draws.
    const engine = layered.engines.get('music-row');
    const tap = layered.hits.find(h => h.id === 'kapa:music-row');
    const booped = engine._boopAt;
    tap.onClick();
    assert.notEqual(engine._boopAt, booped);
});

/** Draws once with `fillRoundRect` and `drawImage` recorded. */
function drawRecorded(scene, width = 608, height = 320) {
    const g = new Gfx(blackHole(), new RecordingText());
    const fills = [], images = [];
    const fill = g.fillRoundRect.bind(g);
    g.fillRoundRect = (...a) => {
        fills.push(a);
        fill(...a);
    };
    g.drawImage = (...a) => images.push(a);
    scene.tick(scene.now + 0.016);
    scene.draw(g, {width, height});
    return {fills, images};
}

const settle = () => new Promise(resolve => setTimeout(resolve, 0));

test('the page\'s clock asks for one frame at the next beat, not one every frame', () => {
    const scene = sceneWith(playingState());
    open(scene);
    const asked = [];
    scene.wantFrameAt = at => asked.push(at);
    draw(scene);
    assert.equal(scene.modulesNeedFrames(), false, 'with Kapa there, the bar keeps no frames coming');
    const interval = scene.moduleFrameInterval();
    assert.ok(interval > 0 && interval <= 1, `the next beat, within a second: ${interval}`);
    assert.ok(asked.some(at => at > scene.now && at <= scene.now + 1 + 1e-9), asked.join(','));
});

test('the fills are as wide as the level and the position: nothing at none, no four-point floor', () => {
    const at = level => {
        const scene = sceneWith(playingState({volume: {level, isMuted: false, shownLevel: level, icon: 'wave1'}, loaded: track({elapsed: 0})}));
        open(scene);
        draw(scene);
        const bar = scene.hits.find(h => h.id === 'music:volume');
        const fills = drawRecorded(scene).fills.filter(f => f[0] === bar.x + 8 && f[3] === 4);
        return fills.map(f => [f[2], f[4]]);
    };
    assert.deepEqual(at(0), [[88, 2]], 'the track alone');
    const small = at(0.02);
    near(small[1][0], 88 * 0.02);
    near(small[1][1], 88 * 0.02 / 2, 'a capsule no wider than it is');
});

test('a dragged volume shows the finger\'s level until the state says the same', () => {
    const volume = {level: 0.5, isMuted: false, shownLevel: 0.5, icon: 'wave2'};
    const scene = sceneWith(playingState({volume}));
    open(scene);
    draw(scene);
    const bar = scene.hits.find(h => h.id === 'music:volume');
    const x0 = bar.x + 8;
    const shown = () => drawRecorded(scene).fills.filter(f => f[0] === x0 && f[3] === 4 && f[2] !== 88).map(f => f[2]);
    scene.press(x0 + 66, bar.y + 10);
    near(shown()[0], 66, 'while dragging');
    scene.release(x0 + 66, bar.y + 10);
    near(shown()[0], 66, 'let go, before the audio system answers');
    scene.setModel(deriveModel({providers: [], pages: ['capacity', 'music'], showsKapa: true,
        modules: {music: playingState({volume: {level: 0.75, isMuted: false, shownLevel: 0.75, icon: 'wave2'}})}}));
    near(shown()[0], 66, 'the answer agrees');
    scene.setModel(deriveModel({providers: [], pages: ['capacity', 'music'], showsKapa: true,
        modules: {music: playingState({volume: {level: 0.3, isMuted: false, shownLevel: 0.3, icon: 'wave1'}})}}));
    near(shown()[0], 88 * 0.3, 'and from then on the state is shown');
});

test('a track without a cover shows its player\'s icon, six tenths the size, centred on the quiet ground', async () => {
    const icon = {};
    const scene = sceneWith(playingState({loaded: track({iconId: 'icon1'}), shown: track({iconId: 'icon1'})}));
    scene.actions.call = (module, method, args) => {
        scene.calls.push([module, method, args]);
        return Promise.resolve(method === 'artwork' ? {png: 'AAAA'} : null);
    };
    scene.actions.decodeImage = () => icon;
    open(scene);
    drawRecorded(scene);
    await settle();
    await settle();
    const page = pageLayout(scene.openWidth, 0, 38, {kapa: true});
    const drawn = drawRecorded(scene).images.find(i => i[0] === icon && i[3] > 40);
    assert.ok(drawn, 'the icon is drawn');
    near(drawn[3], 146 * 0.6);
    near(drawn[2] - page.artwork.y, (146 - 146 * 0.6) / 2);
});

test('decoded pictures of tracks no longer shown are freed', async () => {
    const disposed = [];
    const handle = id => ({id, $dispose: () => disposed.push(id)});
    const withCover = id => playingState({shown: track({artworkId: id}), loaded: track({artworkId: id})});
    const scene = sceneWith(withCover('a'));
    scene.actions.call = (_m, method, args) => Promise.resolve(method === 'artwork' ? {png: args.id} : null);
    scene.actions.decodeImage = png => handle(png);
    draw(scene);
    await settle();
    await settle();
    draw(scene);
    scene.setModel(deriveModel({providers: [], pages: ['capacity', 'music'], showsKapa: true, modules: {music: withCover('b')}}));
    scene.modulesNeedFrames();
    assert.deepEqual(disposed, [], 'the cover drawn is held until the next one is in its place');
    draw(scene);
    await settle();
    await settle();
    draw(scene);
    assert.deepEqual(disposed, ['a'], 'and freed once it is');
});

test('a new track\'s cover on its way: the last one stays in its place for up to two seconds, as MusicPresence holds it', async () => {
    const a = {id: 'a'}, b = {id: 'b'};
    const withCover = id => playingState({shown: track({artworkId: id}), loaded: track({artworkId: id})});
    const scene = sceneWith(withCover('hold-a'));
    let release;
    scene.actions.call = (_m, method, args) => method !== 'artwork' ? Promise.resolve(null)
        : args.id === 'hold-a' ? Promise.resolve({png: 'a'}) : new Promise(resolve => { release = () => resolve({png: 'b'}); });
    scene.actions.decodeImage = png => (png === 'a' ? a : b);
    open(scene);
    drawRecorded(scene);
    await settle();
    await settle();
    assert.ok(drawRecorded(scene).images.some(i => i[0] === a), 'the first cover is drawn');
    scene.setModel(deriveModel({providers: [], pages: ['capacity', 'music'], showsKapa: true, expanded: true, modules: {music: withCover('hold-b')}}));
    const waiting = drawRecorded(scene).images;
    assert.ok(waiting.some(i => i[0] === a) && !waiting.some(i => i[0] === b), 'no blink: the old cover holds while the new one is read');
    release();
    await settle();
    await settle();
    const after = drawRecorded(scene).images;
    assert.ok(after.some(i => i[0] === b) && !after.some(i => i[0] === a), 'the new cover takes its place');
});

/** Ticks the scene on a 60 Hz clock from `from` for `seconds`, calling `each(scene)` after every tick. */
function run(scene, from, seconds, each = () => {}) {
    for (let t = from; t <= from + seconds + 1e-9; t += 1 / 60) {
        scene.tick(t);
        each(scene);
    }
    return from + seconds;
}

test('a window covering the screen: the row fades away as the shape closes up on the closing spring, and comes back the same way', () => {
    const scene = sceneWith(playingState());
    scene.tick(0);
    scene.time = () => scene.now;
    run(scene, 0, 1);
    assert.equal(scene.height.value, 38 + 54);
    assert.equal(scene.setFullscreen(true), true);
    assert.equal(scene.setFullscreen(true), false, 'told twice, it moves once');
    assert.equal(scene.height.target, 38, 'the strip alone');
    assert.equal(scene.height.response, 0.45, 'on the closing spring');
    assert.equal(scene.height.damping, 1.0);
    assert.ok(scene.height.value > 38 + 53, 'not a jump');
    // The row is still drawn, fading, and no longer pressed or heard.
    let text = draw(scene);
    assert.ok(text.calls.some(c => c.str === 'Mad Technology'), 'the row as it was, fading');
    assert.ok(!scene.hits.some(h => h.id.startsWith('music-row:')), 'its buttons are gone at once');
    const heights = [], shares = [];
    let t = run(scene, 1.02, 1.5, s => {
        heights.push(s.height.value);
        shares.push(s.shownRow()?.share ?? 0);
    });
    assert.ok(heights.some(h => h > 40 && h < 90), 'seen on its way');
    assert.ok(heights.every((h, i) => i === 0 || h <= heights[i - 1] + 1e-9), 'critically damped: no overshoot');
    assert.ok(shares.slice(0, 3).some(v => v > 0 && v < 1), 'the row fades');
    const gone = shares.findIndex(v => v === 0);
    assert.ok(gone > 0 && gone <= 8, `gone within its 0.1 s fade, not left over the application (${gone} frames)`);
    assert.equal(scene.height.value, 38);
    assert.equal(scene.atRest, true);
    text = draw(scene);
    assert.ok(!text.calls.some(c => c.str === 'Mad Technology'), 'nothing of the row over the application');
    assert.equal(scene.shownRow(), null);

    // The window goes: the shape grows back on the same spring, and the row arrives a beat behind it.
    scene.setFullscreen(false);
    assert.equal(scene.height.target, 38 + 54);
    assert.equal(scene.shownRow().share, 0, 'from nothing');
    const back = [];
    t = run(scene, t + 0.02, 1.5, s => back.push([s.height.value, s.shownRow().share]));
    assert.ok(back.some(([h]) => h > 40 && h < 90), 'growing, seen on its way');
    assert.ok(back.some(([, v]) => v > 0 && v < 1), 'the row fades in');
    assert.ok(back.slice(0, 3).every(([, v]) => v === 0), 'a beat behind the shape (0.06 s)');
    assert.equal(scene.height.value, 38 + 54);
    assert.equal(scene.shownRow().share, 1);
    assert.equal(scene.atRest, true);
    draw(scene);
    assert.ok(scene.hits.some(h => h.id === 'music-row:toggle'), 'and its buttons are back');
});

test('turned back half-way, the row fades back from where it had got to', () => {
    const scene = sceneWith(playingState());
    scene.tick(0);
    scene.time = () => scene.now;
    run(scene, 0, 1);
    scene.setFullscreen(true);
    run(scene, 1.02, 0.05);
    const half = scene.shownRow().share;
    assert.ok(half > 0 && half < 1, String(half));
    scene.setFullscreen(false);
    assert.equal(scene.shownRow().share, half, 'no jump to nothing');
    run(scene, 1.1, 1.5);
    assert.equal(scene.shownRow().share, 1);
    assert.equal(scene.height.value, 38 + 54);
});

test('under Reduce Motion the row goes on a short ease in and out, with no spring', () => {
    const scene = sceneWith(playingState());
    scene.setModel({reduceMotion: true});
    scene.tick(0);
    scene.time = () => scene.now;
    run(scene, 0, 1);
    scene.setFullscreen(true);
    const heights = [];
    run(scene, 1.0, 0.3, s => heights.push(s.height.value));
    // 0.15 s: nine frames at 60 Hz, and there.
    assert.ok(heights[3] > 38 && heights[3] < 92, String(heights[3]));
    assert.equal(heights[10], 38, 'there in 0.15 s');
    assert.ok(heights.every(h => h >= 38 && h <= 92));
    assert.equal(scene.shownRow(), null);
    scene.setFullscreen(false);
    const shares = [];
    run(scene, 1.4, 0.3, s => shares.push(s.shownRow().share));
    assert.ok(shares[0] > 0 && shares[0] < 1, 'no beat behind under Reduce Motion');
    assert.equal(shares[10], 1);
});

test('open, a covering window changes nothing seen; closing, the row is simply there or not', () => {
    const scene = sceneWith(playingState());
    scene.tick(0);
    scene.time = () => scene.now;
    scene.expand();
    run(scene, 0, 1.5);
    const width = scene.width.value, height = scene.height.value;
    scene.setFullscreen(true);
    assert.equal(scene.coverFade.value, 1);
    run(scene, 1.6, 0.3);
    assert.equal(scene.width.value, width);
    assert.equal(scene.height.value, height);
    scene.collapse();
    run(scene, 2, 1.5);
    assert.equal(scene.height.value, 38, 'closed over the application: the strip alone');
    assert.equal(scene.shownRow(), null);
});

test('the row\'s layer hands the row back to the surface for the motion, and takes it again at rest', () => {
    const scene = sceneWith(playingState(), {showsKapa: false});
    scene.liveLayers = true;
    scene.tick(0);
    scene.time = () => scene.now;
    run(scene, 0, 1);
    scene.planLayers();
    assert.ok(scene.layers.has('row'), 'the bars on their layer, at rest');
    scene.setFullscreen(true);
    // Before the next drawing of the whole, the layer still draws the row as the surface would.
    const layerText = [];
    let drew = 0;
    const cr = new Proxy({}, {get: (_t, name) => (...a) => { if (name === 'fill' || name === 'rectangle') drew++; return undefined; }});
    scene.drawLayer('row', new Gfx(cr, {measure: () => 0, draw: (...a) => layerText.push(a)}), 304);
    assert.ok(drew > 0, 'the layer is not left empty while the surface leaves the bars to it');
    // The next drawing of the whole takes them back: drawn by the surface, once.
    scene.tick(1.02);
    assert.ok(!scene.planLayers().has('row'), 'no layer while it moves');
    assert.equal(scene.rowLayerReady(), false);
    run(scene, 1.04, 1.5, s => assert.ok(!s.planLayers().has('row'), 'none over the application either'));
    scene.setFullscreen(false);
    run(scene, 2.6, 0.2, s => assert.ok(!s.planLayers().has('row'), 'none while the row comes back'));
    run(scene, 2.8, 1.5);
    assert.equal(scene.rowLayerReady(), true, 'at rest again, on its layer');
    assert.ok(scene.planLayers().has('row'));
});

test('the Script\'s row shows over a covering window too: nothing fades, nothing moves', () => {
    const scene = sceneWith(playingState());
    scene.tick(0);
    scene.time = () => scene.now;
    run(scene, 0, 1);
    scene.compactRow = () => ({height: 40, wide: true, draw: () => {}, module: {id: 'teleprompter'}, priority: 20});
    scene.setModel({});
    run(scene, 1, 1.5);
    const height = scene.height.value;
    scene.setFullscreen(true);
    assert.equal(scene.coverFade.value, 1);
    assert.equal(scene.height.target, height);
    assert.equal(scene.atRest, true);
});
