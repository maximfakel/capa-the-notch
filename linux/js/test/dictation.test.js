// Run with: node --test linux/js/test/*.test.js
import assert from 'node:assert/strict';
import test from 'node:test';

import {Gfx, RecordingText} from '../ui/gfx.js';
import {SurfaceScene} from '../ui/scene.js';
import dictation, {BELOW_SURFACE, GAP, KAPA_SIZE, MARGIN, ORB, capsuleSize} from '../ui/modules/dictation.js';
import {PRESSED_OPACITY} from '../ui/widgets.js';
import {MurmurClock, SEEDS, catchlight, drawOrb, drift, ease, lit, palette, rimWeight, shade, stateTerms} from '../ui/modules/orb.js';

function recorder() {
    const calls = [];
    return new Proxy({calls}, {
        get: (target, name) => name === 'calls' ? calls : (...args) => { calls.push([name, ...args]); },
    });
}

const TEAL = {tone: [34 / 255, 183 / 255, 202 / 255], tone2: [86 / 255, 223 / 255, 154 / 255]};

const state = (presentation, extra = {}) => ({
    enabled: true, presentation, isDrawn: presentation !== 'hidden', followsVoice: presentation === 'recording',
    hasDetails: presentation === 'error' || presentation === 'copied',
    orb: {state: {hidden: 'idle', recording: 'listening', recognizing: 'thinking', inserted: 'success', copied: 'success', error: 'error'}[presentation], ...TEAL},
    kapa: {recording: 'listening', recognizing: 'thinking', inserted: 'inserted', copied: 'copied', error: 'failed', hidden: 'rest'}[presentation],
    accessibilityLabel: 'Dictation', level: 0.4, details: null, ...extra,
});

function sceneWith(dictationState, model = {}) {
    const calls = [];
    const scene = new SurfaceScene({barHeight: 38, notchWidth: 0}, {call: (...a) => calls.push(a), openSettings: () => calls.push(['openSettings'])});
    scene.setModel({providers: [], modules: {dictation: dictationState}, ...model});
    scene.tick(1);
    return {scene, calls};
}

/** A tap: the button goes down and comes up in the same place. */
const tap = (scene, x, y) => {
    scene.press(x, y);
    scene.release?.(x, y);
};

const draw = scene => {
    const text = new RecordingText();
    const cr = recorder();
    scene.draw(new Gfx(cr, text), {width: 700, height: 500, cx: 350});
    return {text, cr};
};

test('the capsule is the orb alone, or the orb and Kapa side by side, tops level', () => {
    assert.deepEqual(capsuleSize(false), {width: 100, height: 100});
    assert.deepEqual(capsuleSize(true), {width: ORB + GAP + KAPA_SIZE, height: KAPA_SIZE});
    assert.equal(ORB + GAP + KAPA_SIZE, 242);
});

test('nothing hangs under the surface while hidden', () => {
    const {scene} = sceneWith(state('hidden'));
    assert.deepEqual(scene.overlays(350), []);
    assert.ok(scene.extent().bottom <= 40, 'the window need not grow');
});

test('it hangs twelve points under the shape with the orb centred and Kapa to its right', () => {
    const {scene} = sceneWith(state('recording'), {showsKapa: true});
    const [overlay] = scene.overlays(350);
    const bottom = scene.height.value;
    assert.equal(overlay.frame.x, 350 - ORB / 2 - MARGIN, 'the orb is centred under the surface');
    assert.equal(overlay.frame.y, bottom + BELOW_SURFACE - MARGIN);
    assert.equal(overlay.frame.width, 242 + 2 * MARGIN);
    assert.equal(overlay.frame.height, 136 + 2 * MARGIN);
    const alone = sceneWith(state('recording'), {showsKapa: false}).scene.overlays(350)[0];
    assert.equal(alone.frame.width, 100 + 2 * MARGIN);
    assert.equal(alone.frame.x, overlay.frame.x, 'Kapa grows to the right; the orb stays put');
});

test('the host is told how far the drawing reaches', () => {
    const {scene} = sceneWith(state('recording'), {showsKapa: true});
    const extent = scene.extent();
    assert.equal(extent.right, -ORB / 2 + 242 + MARGIN, 'Kapa and her margin to the right of the middle');
    assert.ok(extent.bottom >= scene.height.value + BELOW_SURFACE + 136, 'and the capsule under the shape');
    assert.ok(extent.left >= scene.width.value / 2);
});

test('every state draws the orb, and a recording draws Kapa too, without a NaN', () => {
    for (const presentation of ['recording', 'recognizing', 'inserted', 'copied', 'error']) {
        const {scene} = sceneWith(state(presentation), {showsKapa: true});
        const {cr} = draw(scene);
        assert.ok(cr.calls.length > 100, presentation);
        assert.ok(!cr.calls.some(c => c.slice(1).some(v => typeof v === 'number' && Number.isNaN(v))), `${presentation} drew a NaN`);
    }
});

test('only an outcome with something to say is a button, and its tap opens the details', () => {
    const {scene} = sceneWith(state('error', {details: {title: 'Dictation stopped', body: 'Try again.', offersSettings: true}}));
    draw(scene);
    const hit = scene.hits.find(h => h.id === 'dictation:capsule');
    assert.ok(hit, 'an error can be tapped');
    tap(scene, hit.x + 5, hit.y + 5);
    draw(scene);
    assert.ok(scene.hits.some(h => h.id === 'dictation:dismiss'));
    assert.ok(scene.hits.some(h => h.id === 'dictation:settings'), 'an error offers Settings');

    const inserted = sceneWith(state('inserted')).scene;
    draw(inserted);
    assert.ok(!inserted.hits.some(h => h.id === 'dictation:capsule'), 'an insertion has nothing to open');
});

test('the details say what the state says and Dismiss cancels', () => {
    const {scene, calls} = sceneWith(state('copied', {details: {title: 'Text copied, not inserted', body: 'The text could not be pasted. It is still in the clipboard.', offersSettings: false}}));
    draw(scene);
    tap(scene, ...(() => { const h = scene.hits.find(x => x.id === 'dictation:capsule'); return [h.x + 1, h.y + 1]; })());
    const {text} = draw(scene);
    const said = text.calls.map(c => c.str).join(' ');
    assert.match(said, /Text copied, not inserted/);
    assert.match(said, /still/);
    assert.ok(!scene.hits.some(h => h.id === 'dictation:settings'), 'a copy does not offer Settings');
    const dismiss = scene.hits.find(h => h.id === 'dictation:dismiss');
    tap(scene, dismiss.x + 3, dismiss.y + 3);
    assert.deepEqual(calls.at(-1), ['dictation', 'dismiss']);
});

test('the popover is transient: a press anywhere else in the panel closes it as it goes down, and is not taken', () => {
    const {scene, calls} = sceneWith(state('error', {details: {title: 'Dictation stopped', body: 'Try again.', offersSettings: true}}));
    draw(scene);
    const capsule = scene.hits.find(h => h.id === 'dictation:capsule');
    tap(scene, capsule.x + 5, capsule.y + 5);
    draw(scene);
    assert.ok(scene.dictation.details);
    // Its own button still answers.
    const dismiss = scene.hits.find(h => h.id === 'dictation:dismiss');
    assert.equal(scene.hitAt(dismiss.x + 3, dismiss.y + 3), dismiss);
    // A press in the panel's margin, beside the capsule.
    const frame = scene.overlays(350)[0].frame;
    assert.equal(scene.listensOutside(), true, 'while it is open the host hears presses elsewhere');
    assert.equal(scene.press(frame.x + 2, capsule.y + 5), false, 'nothing takes the press: it goes on to what is under it');
    assert.equal(scene.dictation.details, false, 'closed on the press, before the release');
    scene.release(frame.x + 2, capsule.y + 5);
    draw(scene);
    assert.ok(!scene.hits.some(h => h.id === 'dictation:dismiss' || h.id === 'dictation:outside'));
    assert.ok(!calls.some(c => c[1] === 'dismiss'), 'closing it is not dismissing the outcome');
    // Closed, a press there is nobody's.
    assert.equal(scene.press(frame.x + 2, capsule.y + 5), false);
    draw(scene);
    assert.equal(scene.listensOutside(), false);
});

test('the popover closes on a press anywhere outside the surface, and stays for one on itself', () => {
    const {scene} = sceneWith(state('error', {details: {title: 'Dictation stopped', body: 'Try again.', offersSettings: true}}));
    draw(scene);
    const capsule = scene.hits.find(h => h.id === 'dictation:capsule');
    tap(scene, capsule.x + 5, capsule.y + 5);
    draw(scene);
    // A press on the popover, not on a button: it stays.
    const pop = scene.dictation.popover;
    assert.ok(pop && pop.w === 310, JSON.stringify(pop));
    scene.press(pop.x + 4, pop.y + pop.h - 4);
    scene.release(pop.x + 4, pop.y + pop.h - 4);
    assert.equal(scene.dictation.details, true);
    // A press on the strip, inside the surface: it closes, and the strip still takes it.
    let changed = 0;
    const was = scene.onChange;
    scene.onChange = () => { changed++; was(); };
    const strip = scene.hits.find(h => h.id === 'strip');
    assert.equal(scene.press(strip.x + 5, strip.y + 5), true);
    scene.release(strip.x + 5, strip.y + 5, {cancel: true});
    assert.equal(scene.dictation.details, false);
    assert.ok(changed > 0);
    // Opened again, a press somewhere else on the screen closes it.
    tap(scene, capsule.x + 5, capsule.y + 5);
    draw(scene);
    assert.equal(scene.dictation.details, true);
    assert.equal(scene.pressOutside(), true);
    assert.equal(scene.dictation.details, false);
    assert.equal(scene.pressOutside(), false, 'closed, there is nothing to close');
});

test('the capsule is a plain button: held down, all of it dims as one', () => {
    const {scene} = sceneWith(state('error', {details: {title: 'Dictation stopped', body: 'Try again.', offersSettings: true}}));
    draw(scene);
    const fades = () => {
        const g = new Gfx(recorder(), new RecordingText());
        const seen = [];
        const group = g.group.bind(g);
        g.group = (alpha, fn) => {
            seen.push(alpha);
            group(alpha, fn);
        };
        scene.draw(g, {width: 700, height: 500, cx: 350});
        return seen.filter(a => a === PRESSED_OPACITY).length;
    };
    assert.equal(fades(), 0);
    const capsule = scene.hits.find(h => h.id === 'dictation:capsule');
    scene.press(capsule.x + 5, capsule.y + 5);
    assert.equal(fades(), 1);
    scene.release(capsule.x + 5, capsule.y + 5, {cancel: true});
    assert.equal(fades(), 0);
});

test('the pointer passes through the transparent window except over the capsule', () => {
    const {scene} = sceneWith(state('recording'));
    assert.ok(dictation.needsFrames({module: state('recording')}));
    assert.ok(!dictation.needsFrames({module: state('hidden')}));
    assert.ok(!scene.idle, 'a drawn capsule keeps the frames coming');
});

test('the orb: success drives a lap and closes the ring once; responding drives; idle does neither', () => {
    assert.deepEqual(stateTerms(0, 5), {complete: 0, sweep: 0, settled: 0, drive: 0});
    const early = stateTerms(4, 0.25), late = stateTerms(4, 1.2);
    assert.ok(early.complete > 0.5 && late.complete < 0.05, 'the ring closes for a breath, then opens');
    assert.ok(late.settled > 0.95 && late.sweep === 1);
    assert.ok(stateTerms(3, 1).drive === 1);
});

test('the arc drifts forward and never stalls or reverses', () => {
    let last = drift(0, 0.54, 0.62, 1);
    for (let t = 0.05; t < 40; t += 0.05) {
        const now = drift(t, 0.54, 0.62, 1);
        assert.ok(now > last, `stalled at ${t}`);
        last = now;
    }
});

test('the orb draws dark glass, a rim, an arc of light and a catchlight, and the voice thickens the arc', () => {
    const g1 = new Gfx(recorder(), new RecordingText());
    drawOrb(g1, 0, 0, 100, {state: 'listening', ...TEAL, level: 0, t: 3, tau: 5});
    const quiet = g1.cr.calls.filter(c => c[0] === 'setLineWidth').map(c => c[1]);
    const g2 = new Gfx(recorder(), new RecordingText());
    drawOrb(g2, 0, 0, 100, {state: 'listening', ...TEAL, level: 1, t: 3, tau: 5});
    const loud = g2.cr.calls.filter(c => c[0] === 'setLineWidth').map(c => c[1]);
    assert.ok(Math.max(...loud) > Math.max(...quiet), 'a voice widens the band');
    assert.ok(g1.cr.calls.filter(c => c[0] === 'setSourceRadial').length >= 3, 'body, interior wash and catchlight');
});

test('the clock integrates the tempo: steady, it is speed × elapsed, and a state change does not jump it', () => {
    const clock = new MurmurClock();
    clock.frame('listening', 10, 0);
    let f = clock.frame('listening', 12, 0);
    assert.ok(Math.abs(f.phase - 2 * SEEDS.listening.speed) < 1e-9, 'two seconds at listening tempo');
    // Into the error at second 12: the phase carries on from where it was.
    const before = f.phase;
    f = clock.frame('error', 12, 0);
    assert.ok(Math.abs(f.phase - before) < 1e-9, 'no jump at the change');
    let last = f.phase;
    for (let t = 12.03; t < 14; t += 1 / 30) {
        const next = clock.frame('error', t, 0).phase;
        assert.ok(next - last < 0.05, `a jump at ${t}`);
        last = next;
    }
});

test('the clock starts from zero when the capsule appears, and limn never restarts the arc after', () => {
    const clock = new MurmurClock();
    assert.equal(clock.frame('listening', 100, 0).phase, 0, 'appearing is zero, whatever the uptime');
    const listened = clock.frame('listening', 103, 0).phase;
    assert.ok(Math.abs(listened - 3 * SEEDS.listening.speed) < 1e-9);
    // limn has no settle arc (`MurmurStyle.hasArc`), so thinking and success carry on.
    assert.ok(Math.abs(clock.frame('thinking', 103, 0).phase - listened) < 1e-9, 'thinking carries on');
    const thinking = clock.frame('thinking', 104, 0).phase;
    assert.ok(thinking - listened > SEEDS.listening.speed, 'and wakes faster than the tempo it left');
    assert.ok(Math.abs(clock.frame('success', 104, 0).phase - thinking) < 1e-9, 'success carries on too');
});

test('a state change crosses the design over 0.6 s, eased', () => {
    assert.equal(ease(0), 0);
    assert.equal(ease(0.3), 0.5);
    assert.equal(ease(0.6), 1);
    const clock = new MurmurClock();
    clock.frame('listening', 0, 0);
    clock.frame('error', 1, 0);
    const mid = clock.frame('error', 1.3, 0);
    assert.ok(Math.abs(mid.depth - (SEEDS.listening.depth + SEEDS.error.depth) / 2) < 1e-9);
    assert.ok(Math.abs(mid.hueShift - SEEDS.error.hueShift / 2) < 1e-9);
    const done = clock.frame('error', 2, 0);
    assert.equal(done.hueShift, -0.35, 'the error walks the hue down the family');
    assert.equal(done.depth, 1.20);
});

test('the voice is smoothed: the first frame snaps, it rises fast and falls slowly, and lifts the light', () => {
    const clock = new MurmurClock();
    assert.equal(clock.frame('listening', 0, 0.8).level, 0.8, 'the first frame snaps');
    const fell = clock.frame('listening', 0.05, 0).level;
    assert.ok(fell > 0.6, `a release of a quarter second: ${fell}`);
    const quiet = new MurmurClock();
    quiet.frame('listening', 0, 0);
    const rose = quiet.frame('listening', 0.05, 1).level;
    assert.ok(rose > 0.6, `an attack of a twentieth: ${rose}`);
    const loud = new MurmurClock();
    assert.ok(Math.abs(loud.frame('listening', 0, 1).glow - SEEDS.listening.glow * 1.35) < 1e-9, 'glow × (1 + 0.35 · level)');
    const stalled = new MurmurClock();
    stalled.frame('listening', 0, 0);
    const step = stalled.frame('listening', 10, 1).level;
    const capped = new MurmurClock();
    capped.frame('listening', 0, 0);
    assert.equal(step, capped.frame('listening', 0.25, 1).level, 'a long gap is a quarter second at most');
});

test('Reduce Motion draws one still frame, four seconds in, with the raw level and no entry', () => {
    const clock = new MurmurClock();
    const a = clock.frame('success', 1, 0.5, {reduced: true});
    const b = clock.frame('success', 9, 0.5, {reduced: true});
    assert.deepEqual(a, b);
    assert.equal(a.tau, 4);
    assert.equal(a.phase, 4 * SEEDS.success.speed);
    assert.equal(a.level, 0.5);
    assert.ok(Math.abs(a.glow - SEEDS.success.glow * 1.175) < 1e-9, 'no swell');
});

test('the colours walk the OKLCH rail: a pale hot end with an emissive lift, the tail turned down the hue', () => {
    const ink = [23 / 255, 23 / 255, 23 / 255];
    const p = palette(ink, TEAL.tone, TEAL.tone2, 0, 1.1);
    assert.ok(p.s3[0] <= 0.93 && p.s3[0] > p.s2[0], 'the hot end is lighter than the tone, capped at 0.93');
    assert.ok(Math.hypot(p.s3[1], p.s3[2]) < Math.hypot(p.s2[1], p.s2[2]), 'and paler');
    const zero = lit(p, 0, 1);
    assert.ok(zero.every((c, i) => Math.abs(c - ink[i]) < 0.01), 'no energy is the ink');
    const hot = lit(p, 1.2, 1.1);
    assert.ok(hot.every(c => c <= 1) && hot[1] > 0.8, 'the head burns pale');
    assert.ok(Math.max(...hot) < 1 || Math.min(...hot) < 0.98, 'tinted, not white');
    const head = shade(p, 0.7, 0), tail = shade(p, 0.7, -0.2);
    assert.notDeepEqual(head, tail, 'the tail is turned');
    const error = palette(ink, [229 / 255, 62 / 255, 62 / 255], [1, 122 / 255, 92 / 255], -0.35, 1.2);
    const plain = palette(ink, [229 / 255, 62 / 255, 62 / 255], [1, 122 / 255, 92 / 255], 0, 1.2);
    const hue = s => Math.atan2(s[2], s[1]);
    assert.ok(Math.abs(hue(error.s2) - hue(plain.s2) + 0.35) < 1e-9, 'the error walks the hue −0.35');
});

test('the catchlight sits up and to the left where the key light says, and drifts', () => {
    const at = catchlight(0);
    assert.ok(Math.abs(at.x + 0.29) < 0.02 && Math.abs(at.y + 0.33) < 0.02, JSON.stringify(at));
    const later = catchlight(15);
    assert.ok(Math.hypot(later.x - at.x, later.y - at.y) > 0.005, 'the key drifts');
});

test('the orb sits on an opaque ink disc the size of its frame', () => {
    const g = new Gfx(recorder(), new RecordingText());
    drawOrb(g, 0, 0, 100, {state: 'listening', ...TEAL, phase: 1, tau: 5});
    const calls = g.cr.calls;
    const first = calls.findIndex(c => c[0] === 'setSourceRGBA');
    assert.deepEqual(calls[first].slice(1), [23 / 255, 23 / 255, 23 / 255, 1]);
    const arc = calls.slice(first).find(c => c[0] === 'arc');
    assert.deepEqual(arc.slice(1, 4), [50, 50, 50], 'radius 50, centred');
});

test('the light stays inside the glass: clipped to the body, each arc segment exactly its own lap, added', () => {
    const g = new Gfx(recorder(), new RecordingText());
    drawOrb(g, 0, 0, 100, {state: 'listening', ...TEAL, level: 0.7, phase: 3, tau: 5});
    const calls = g.cr.calls;
    const clip = calls.findIndex(c => c[0] === 'clip');
    assert.ok(clip > 0, 'clipped');
    const body = calls.slice(0, clip).reverse().find(c => c[0] === 'arc');
    assert.deepEqual(body.slice(1, 4), [50, 50, 30], 'to the body, R = 0.3 of the frame');
    const band = calls.filter(c => c[0] === 'arc' && Math.abs(c[3] - 30 * 0.965) < 1e-9);
    assert.ok(band.length > 10);
    for (const c of band)
        assert.ok(Math.abs(c[5] - c[4] - Math.PI * 2 / 144) < 1e-9, 'one lap, no overlap');
    assert.ok(calls.some(c => c[0] === 'setOperator' && c[1] === 12), 'neighbours add, so their shared edges leave no seam');
    assert.equal(calls.filter(c => c[0] === 'pushGroup').length, calls.filter(c => c[0] === 'popGroupToSource').length);
});

test('the thin rim is brighter away from the key and under the sky, and the catchlight is near-white', () => {
    assert.ok(rimWeight(Math.atan2(0.50, 0.42)) > rimWeight(Math.atan2(-0.50, -0.42)) * 1.3, 'away from the key');
    assert.ok(rimWeight(-Math.PI / 2) > rimWeight(Math.PI), 'the top edge takes the sky');
    for (let k = 0; k < 36; k++)
        assert.ok(rimWeight(k * Math.PI / 18) <= 1 + 1e-9);
    const g = new Gfx(recorder(), new RecordingText());
    drawOrb(g, 0, 0, 100, {state: 'listening', ...TEAL, level: 0, phase: 3, tau: 5});
    const radial = g.cr.calls.filter(c => c[0] === 'setSourceRadial');
    const glint = radial.at(-1);
    assert.ok(glint[6] <= 30 * 0.1 + 1e-9, 'a tenth of the body across at most');
    const [, r, gg, b, alpha] = glint[7][0];
    assert.equal(alpha, 1);
    assert.ok(Math.min(r, gg, b) > 0.75, `near-white: ${[r, gg, b]}`);
});

test('Kapa in the capsule is awake, not a button, and does not follow the pointer', () => {
    const {scene} = sceneWith(state('recording'), {showsKapa: true});
    const seen = [];
    const real = scene.drawKapaAt.bind(scene);
    scene.drawKapaAt = (g, key, x, y, size, expression, options) => {
        seen.push(options);
        return real(g, key, x, y, size, expression, options);
    };
    draw(scene);
    assert.ok(seen.length >= 1);
    for (const o of seen)
        assert.deepEqual([o.awake, o.tappable, o.hoverable], [true, false, false]);
    assert.ok(!scene.hits.some(h => h.id === 'kapa:dictation'));
});

test('the capsule and Kapa cast one shadow: the orb\'s disc and Kapa\'s shape, five down', () => {
    const {scene} = sceneWith(state('recording'), {showsKapa: true});
    const {cr} = draw(scene);
    assert.ok(cr.calls.some(c => c[0] === 'pushGroup'), 'Kapa drawn into a group');
    assert.ok(cr.calls.some(c => c[0] === 'setOperator' && c[1] === 5), 'and turned black where it covers');
    const shadow = cr.calls.find(c => c[0] === 'setSourceRadial');
    const [, x0, y0, r0, , , r1] = shadow;
    assert.equal(r0, 41);
    assert.equal(r1, 59);
    const overlay = scene.overlays(350)[0];
    assert.equal(y0, overlay.frame.y + MARGIN + ORB / 2 + 5);
    assert.equal(x0, overlay.frame.x + MARGIN + ORB / 2);
});

test('the capsule hangs from where the surface is going, not where it is on the way', () => {
    const {scene} = sceneWith(state('recording'));
    scene.height.to(scene.height.value + 120);
    const [overlay] = scene.overlays(350);
    assert.equal(overlay.frame.y, scene.height.target + BELOW_SURFACE - MARGIN);
});

test('Reduce Motion stops asking for frames', () => {
    const {scene} = sceneWith(state('recording'), {reduceMotion: true});
    assert.ok(!dictation.needsFrames({module: state('recording'), scene}));
});

test('the popover is centred on the whole capsule, its title a headline, its colours the appearance\'s', () => {
    const details = {title: 'Dictation stopped', body: 'Try again.', offersSettings: true};
    const open = model => {
        const {scene} = sceneWith(state('error', {details}), {showsKapa: true, ...model});
        draw(scene);
        const hit = scene.hits.find(h => h.id === 'dictation:capsule');
        tap(scene, hit.x + 5, hit.y + 5);
        const drawn = draw(scene);
        return {scene, hit, ...drawn};
    };
    const {scene, hit, text} = open({appearance: 'light'});
    const title = text.calls.find(c => c.str === 'Dictation stopped');
    assert.equal(title.font.weight, 600, '`.headline`: semibold');
    assert.ok(title.rgba[0] < 0.2, 'dark words on a light popover');
    const settings = scene.hits.find(h => h.id === 'dictation:settings');
    const centre = hit.x + hit.w / 2;
    assert.equal(settings.x, centre - 155 + 18, 'centred on the orb and Kapa together');
    const frame = scene.overlays(350)[0].frame;
    assert.ok(frame.x <= centre - 155 && frame.x + frame.width >= centre + 155, 'the window holds all of it');
    const dark = open({appearance: 'dark'}).text.calls.find(c => c.str === 'Dictation stopped');
    assert.ok(dark.rgba[0] > 0.8, 'light words on a dark one');
});

// MARK: - The shell's host (gnome-extension/…/dictation-host.js), over stand-ins for the shell

/** The shell's modules, as stand-ins the tests set up on `globalThis.__shell`. */
const shellModules = `
export async function resolve(specifier, context, next) {
    if (specifier.startsWith('gi://') || specifier.startsWith('resource:///'))
        return {url: 'stub:' + specifier, shortCircuit: true};
    return next(specifier, context);
}
export async function load(url, context, next) {
    if (!url.startsWith('stub:'))
        return next(url, context);
    // Each reads the stand-in of the moment, so every test can set up its own.
    const name = url.slice('stub:'.length);
    const of = path => 'new Proxy({}, {get: (_, k) => globalThis.__shell' + path + '[k]})';
    const source = name.endsWith('main.js')
        ? 'export const wm = ' + of('.Main.wm') + ', uiGroup = ' + of('.Main.uiGroup') + ';' +
          'export const pushModal = (...a) => globalThis.__shell.Main.pushModal(...a);' +
          'export const popModal = (...a) => globalThis.__shell.Main.popModal(...a);'
        : 'export default ' + of('[' + JSON.stringify(name.slice('gi://'.length)) + ']') + ';';
    return {format: 'module', source, shortCircuit: true};
}`;

const MODIFIERS = {CONTROL_MASK: 1 << 2, SHIFT_MASK: 1 << 0, MOD1_MASK: 1 << 3, MOD4_MASK: 1 << 6, SUPER_MASK: 1 << 26};

function shell() {
    const clipboard = [];
    const keys = [];
    const signals = [];
    const listeners = [];
    let focused = {id: 7, wmClass: 'gedit'};
    let now = 1_000_000;
    const stage = {
        Clutter: {
            ModifierType: MODIFIERS, EVENT_STOP: true, KEY_Escape: 0xff1b,
            KeyState: {PRESSED: 1, RELEASED: 0}, InputDeviceType: {KEYBOARD_DEVICE: 1},
            get_default_backend: () => ({get_default_seat: () => ({
                create_virtual_device: () => ({notify_key: (_t, key, state) => keys.push([key, state])}),
            })}),
        },
        GLib: {
            PRIORITY_DEFAULT: 0, SOURCE_REMOVE: false, SOURCE_CONTINUE: true,
            get_monotonic_time: () => now,
            timeout_add: () => 1, timeout_add_seconds: () => 2, source_remove: () => {},
            filename_to_uri: path => `file://${path}`, Bytes: class {},
        },
        Meta: {
            KeyBindingFlags: {NONE: 0}, KeyBindingAction: {NONE: 0},
            external_binding_name_for_action: action => `external-${action}`,
            SelectionType: {SELECTION_CLIPBOARD: 2},
        },
        Shell: {
            ActionMode: {NONE: 0, ALL: ~0},
            WindowTracker: {get_default: () => ({get_window_app: () => null})},
        },
        St: {
            ClipboardType: {CLIPBOARD: 1},
            Clipboard: {get_default: () => ({set_text: (_type, text) => clipboard.push(text)})},
            Widget: class { connect() {} grab_key_focus() {} destroy() {} },
        },
        Atspi: {
            init: () => 0,
            Role: {PASSWORD_TEXT: 40, TEXT: 61},
            EventListener: {new: callback => {
                const listener = {callback, events: [], register(e) { this.events.push(e); }, deregister(e) { this.events = this.events.filter(x => x !== e); }};
                listeners.push(listener);
                return listener;
            }},
        },
        Main: {
            wm: {allowKeybinding: () => {}},
            uiGroup: {add_child: () => {}},
            pushModal: () => null, popModal: () => {},
        },
    };
    globalThis.__shell = stage;
    let pointer = 0;
    const window = () => focused && {
        get_id: () => focused.id, get_wm_class: () => focused.wmClass,
        get_wm_class_instance: () => focused.wmClass, get_gtk_application_id: () => null, get_sandboxed_app_id: () => null,
    };
    Object.assign(globalThis, {
        display: {
            connect: (name, handler) => { signals.push([name, handler]); return signals.length; },
            disconnect: () => {},
            grab_accelerator: () => 5, ungrab_accelerator: () => {},
            get focus_window() { return window(); },
            get_selection: () => ({connect: () => 1, disconnect: () => {}}),
        },
        get_pointer: () => [0, 0, pointer],
    });
    return {
        clipboard, keys, listeners, signals,
        focus: f => { focused = f; },
        press: state => { pointer = state; },
        later: us => { now += us; },
    };
}

let hostModule = null;
let shelfModule = null;
async function host() {
    if (!hostModule) {
        const {register} = await import('node:module');
        register(`data:text/javascript,${encodeURIComponent(shellModules)}`);
        globalThis.__shell = {};
        hostModule = await import('../../gnome-extension/capa-the-notch@capathenotch.tech/dictation-host.js');
        shelfModule = await import('../../gnome-extension/capa-the-notch@capathenotch.tech/shelf-host.js');
    }
    const fake = shell();
    const calls = [];
    const dictation = new hostModule.DictationHost((module, method, args) => {
        calls.push([method, args]);
        return Promise.resolve(null);
    });
    return {dictation, calls, fake, ...hostModule, ShelfHost: shelfModule.ShelfHost};
}

test('a Super chord is held while the pointer says MOD4, as GNOME reports the Super key', async () => {
    const {chordMasks, chordHeld} = await host();
    const masks = chordMasks('<Control><Super>d', MODIFIERS);
    assert.equal(masks.length, 2);
    assert.ok(chordHeld(MODIFIERS.CONTROL_MASK | MODIFIERS.MOD4_MASK, masks), 'MOD4 is the Super key');
    assert.ok(chordHeld(MODIFIERS.CONTROL_MASK | MODIFIERS.SUPER_MASK, masks), 'and so is SUPER');
    assert.ok(!chordHeld(MODIFIERS.MOD4_MASK, masks), 'Control let go ends it');
    assert.ok(!chordHeld(MODIFIERS.CONTROL_MASK, masks), 'Super let go ends it');
    assert.deepEqual(chordMasks('d', MODIFIERS), [], 'no chord, nothing to watch');
    assert.ok(chordHeld(MODIFIERS.CONTROL_MASK | MODIFIERS.MOD1_MASK, chordMasks('<Control><Alt>d', MODIFIERS)));
});

test('a held Super chord is not taken for a quick tap', async () => {
    const {dictation, calls, fake} = await host();
    dictation.update({registration: {shortcut: {keyCode: 2}, accelerator: '<Control><Super>d', evdev: 32, escape: false}});
    globalThis.__shell.Main.pushModal = () => ({});
    fake.press(MODIFIERS.CONTROL_MASK | MODIFIERS.MOD4_MASK);
    dictation._activate(5);
    await Promise.resolve();
    assert.deepEqual(calls.map(c => c[0]), ['shortcut_registered', 'hotkey_pressed'], 'no release yet');
    dictation.destroy();
});

test('dictated text is our own on the clipboard: the Shelf does not keep it', async () => {
    const {dictation, fake, ShelfHost} = await host();
    const pushed = [];
    const shelf = new ShelfHost({shelfState: () => ({pushClipboard: true, wantsClipboard: true}), push: a => pushed.push(a), notify: () => {}});
    let read = 0;
    shelf._read = async () => { read++; };
    dictation.onEvent('copy', {text: 'привет'});
    assert.deepEqual(fake.clipboard, ['привет']);
    shelf._changed();
    assert.equal(read, 0, 'not even read');
    assert.equal(shelf._settle, 0, 'nor waited for');
    fake.later(600_000);
    shelf._changed();
    assert.notEqual(shelf._settle, 0, 'a copy of someone else\'s, later, is');
    dictation.destroy();
});

test('a paste pressed is an insertion, answered at once', async () => {
    const {dictation, calls, fake} = await host();
    dictation.onEvent('insert', {token: 3, text: 'x', target: {window: '7'}});
    assert.deepEqual(calls.at(-1), ['inserted', {token: 3, message: null}]);
    assert.deepEqual(fake.keys, [[29, 1], [47, 1], [47, 0], [29, 0]], 'Ctrl+V by the keys');
    fake.focus({id: 9, wmClass: 'other'});
    dictation.onEvent('insert', {token: 4, text: 'x', target: {window: '7'}});
    assert.equal(calls.at(-1)[1].token, 4);
    assert.match(calls.at(-1)[1].message, /stopped being active/, 'checked before pasting');
    dictation.destroy();
});

test('the hub ending a session lets go of the held key', async () => {
    const {dictation} = await host();
    let ended = 0;
    dictation._endHold = released => { ended++; assert.equal(released, false, 'not a release: nothing is recognised'); };
    dictation.onEvent('end_hold', {});
    assert.equal(ended, 1);
});

test('the Shell never listens to accessibility itself: a client of it inside the compositor stalls the session', async () => {
    const {dictation, fake} = await host();
    dictation.update({registration: {shortcut: {keyCode: 2}, accelerator: '<Control><Alt>d', evdev: 32, escape: false}});
    for (let i = 0; i < 5; i++)
        await new Promise(r => setTimeout(r, 0));
    assert.equal(fake.listeners.length, 0, 'no AT-SPI listener, with a shortcut or without');
    assert.equal(dictation._target().secure, false);
    dictation.destroy();
});
test('on the host\'s layer the capsule is drawn there alone, from where the top bar ends; the surface keeps what answers and is heard', () => {
    const {scene} = sceneWith(state('recording'), {showsKapa: true});
    scene.liveLayers = true;
    scene.tick(2);
    assert.ok(dictation.needsFrames({...scene.pageModel(), module: state('recording')}), 'drawn by the surface, every frame');
    scene.planLayers();
    assert.deepEqual([...scene.layers.keys()], ['overlay:dictation']);
    assert.ok(!dictation.needsFrames({...scene.pageModel(), module: state('recording')}), 'on its layer, the surface asks for none');

    // The panel's margin reaches four points into the bar under the closed surface; the layer starts below it.
    const [overlay] = scene.overlays(350);
    assert.equal(overlay.frame.y, 38 + BELOW_SURFACE - MARGIN);
    assert.deepEqual(scene.layerRect('overlay:dictation', 350),
        {x: overlay.frame.x, y: 38, w: overlay.frame.width, h: overlay.frame.y + overlay.frame.height - 38});

    const {cr} = draw(scene);
    assert.ok(!cr.calls.some(c => c[0] === 'setSourceRadial'), 'the surface draws nothing of it');
    assert.ok(scene.accessibleNodes().some(n => n.id === 'dictation:capsule'), 'but is heard as it');
    assert.deepEqual(scene.dictation.capsule, {x: 350 - ORB / 2, y: 38 + BELOW_SURFACE, w: 242, h: 136});

    const layer = recorder();
    scene.drawLayer('overlay:dictation', new Gfx(layer, new RecordingText()), 350);
    assert.ok(layer.calls.some(c => c[0] === 'setSourceRadial'), 'the layer draws it');
    const clip = layer.calls.findIndex(c => c[0] === 'rectangle');
    assert.deepEqual(layer.calls[clip].slice(1), [overlay.frame.x, 38, overlay.frame.width, overlay.frame.y + overlay.frame.height - 38],
        'as one picture of its own, cut where the bar ends');
    // Kapa's shadow is painted fifteen times: its group is no larger than her square and the margin round it.
    const kapaRoom = [350 - ORB / 2 + ORB + GAP - MARGIN, 38 + BELOW_SURFACE - MARGIN, KAPA_SIZE + 2 * MARGIN, KAPA_SIZE + 2 * MARGIN];
    assert.ok(layer.calls.some(c => c[0] === 'rectangle' && JSON.stringify(c.slice(1)) === JSON.stringify(kapaRoom)));
    assert.equal(scene.layers.get('overlay:dictation').due, scene.now, 'every frame, on the layer');
    assert.equal(scene.accessibleNodes().filter(n => n.id === 'dictation:capsule').length, 1, 'a layer is never heard');
});

test('the voice\'s level alone draws only the capsule\'s layer; anything more wakes the surface', () => {
    const {scene} = sceneWith(state('recording'), {showsKapa: true});
    scene.liveLayers = true;
    scene.tick(2);
    const told = [];
    scene.onChange = () => told.push('surface');
    scene.onLayerChange = key => told.push(key);
    // Drawn by the surface: every change is the surface's.
    scene.setModel({modules: {dictation: state('recording', {level: 0.7})}});
    assert.ok(told.length > 0 && told.splice(0).every(t => t === 'surface'));
    scene.planLayers();
    scene.setModel({modules: {dictation: state('recording', {level: 0.2, remaining: 12})}});
    assert.deepEqual(told.splice(0), ['overlay:dictation']);
    assert.equal(scene.model.modules.dictation.level, 0.2, 'and the state is the new one');
    scene.setModel({modules: {dictation: state('recognizing')}});
    assert.ok(told.length > 0 && told.splice(0).every(t => t === 'surface'));
    scene.setModel({modules: {dictation: state('recording', {level: 0.4})}, providers: [{provider: 'codex'}]});
    assert.ok(told.length > 0 && told.splice(0).every(t => t === 'surface'), 'with something else, the surface');
});

test('with its popover open, or while the surface moves, the capsule is the surface\'s', () => {
    const {scene} = sceneWith(state('error', {details: {title: 'Dictation stopped', body: 'No microphone.', offersSettings: false}}),
        {showsKapa: true});
    scene.liveLayers = true;
    scene.tick(2);
    draw(scene);
    scene.planLayers();
    assert.ok(scene.layers.has('overlay:dictation'));
    tap(scene, scene.dictation.capsule.x + 10, scene.dictation.capsule.y + 10);
    assert.equal(scene.dictation.details, true);
    scene.planLayers();
    assert.ok(!scene.layers.has('overlay:dictation'), 'the popover open');
    scene.dictation.details = false;
    scene.expand();
    scene.tick(2.016);
    scene.planLayers();
    assert.ok(!scene.layers.has('overlay:dictation'), 'opening');
});
