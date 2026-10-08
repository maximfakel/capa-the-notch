// Run with: node --test linux/js/test/*.test.js
import assert from 'node:assert/strict';
import test from 'node:test';

import {Gfx, RecordingText} from '../ui/gfx.js';
import {SurfaceScene} from '../ui/scene.js';
import {SurfaceController} from '../ui/controller.js';
import {deriveModel, stripSides} from '../ui/model.js';
import {Spring} from '../ui/springs.js';
import {t, setDictionary} from '../ui/strings.js';

/** A context that remembers nothing and accepts anything. */
const blackHole = () => new Proxy({}, {get: () => () => {}});

const window5 = (id, label, remaining, extra = {}) => ({
    id, label, durationMinutes: label === '5 hour' ? 300 : 10080, remainingPercentage: remaining,
    remainingFraction: remaining / 100,
    pace: remaining >= 60 ? 'sustainable' : remaining >= 10 ? 'tightening' : 'unsustainable',
    resetsAt: 1_700_003_600, resetKind: 'in', resetIn: '1h', ...extra,
});

const view = (provider, name, extra = {}) => ({
    provider, name, state: 'fresh', guidance: null, reasonRepeatsTheChip: false, needsAPersonFirst: false,
    monthUsedUp: null, switchedOff: false, headline: null, windows: [], ...extra,
});

const off = (provider, name) => view(provider, name, {state: 'disconnected', switchedOff: true});

const two = () => ({
    providers: [
        view('codex', 'Codex', {headline: 'b', windows: [window5('a', '5 hour', 76), window5('b', 'Weekly', 11)]}),
        view('claudeCode', 'Claude Code', {headline: 'a', windows: [window5('a', '5 hour', 99), window5('b', 'Weekly', 92)]}),
        off('openCode', 'OpenCode'),
    ],
});

function sceneWith(state) {
    const clicks = [];
    const scene = new SurfaceScene({barHeight: 38, notchWidth: 0}, {
        refresh: p => clicks.push(['refresh', p]),
        connect: p => clicks.push(['connect', p]),
        openSettings: () => clicks.push(['settings']),
        togglePin: () => scene.togglePin(),
    });
    scene.setModel(deriveModel(state));
    scene.clicks = clicks;
    return scene;
}

function draw(scene, width = 608, height = 320) {
    const text = new RecordingText();
    scene.draw(new Gfx(blackHole(), text), {width, height});
    return text.calls;
}

function settle(scene, seconds = 2) {
    for (let t0 = 0; t0 <= seconds; t0 += 1 / 60)
        scene.tick(t0);
}

test('a spring reaches its target without a jump when retargeted mid-flight', () => {
    const s = new Spring(0, 0.42, 0.8);
    s.to(100);
    let last = 0;
    for (let i = 0; i < 12; i++) {
        s.step(1 / 60);
        assert.ok(Math.abs(s.value - last) < 25, 'no jump');
        last = s.value;
    }
    s.to(0);
    for (let i = 0; i < 400; i++)
        s.step(1 / 60);
    assert.ok(Math.abs(s.value) < 0.01);
    assert.equal(s.settled, true);
});

test('geometry: 370 closed, 560 open, 210 tall open over a 38-point bar', () => {
    const scene = sceneWith(two());
    assert.equal(scene.compactWidth, 370);
    assert.equal(scene.openWidth, 560);
    assert.equal(scene.openHeight, 210);
    assert.equal(new SurfaceScene({barHeight: 38, notchWidth: 220}, {}).compactWidth, 410);
});

test('the strip shows each Provider\'s headline figure beside its mark', () => {
    const scene = sceneWith(two());
    const calls = draw(scene);
    const figures = calls.filter(c => /^\d+%$/.test(c.str));
    assert.deepEqual(figures.map(c => c.str).slice(0, 2), ['76%', '99%']);
    assert.ok(figures[0].x < 304, 'the first stands on the left');
    assert.ok(figures[1].x > 304, 'the second on the right');
});

test('a click on the time in the strip opens the calendar; beside it, the strip pins', () => {
    const scene = sceneWith(two());
    const calendar = [];
    scene.actions.openCalendar = () => calendar.push('calendar');
    scene.setClock('12:34');
    draw(scene);
    const clock = scene.hits.find(h => h.id === 'clock');
    const strip = scene.hits.find(h => h.id === 'strip');
    assert.ok(clock && clock.x > strip.x && clock.x + clock.w < strip.x + strip.w, 'the time stands inside the strip');
    assert.equal(clock.h, 38, 'as tall as the bar');
    scene.click(clock.x + clock.w / 2, 30);
    assert.deepEqual(calendar, ['calendar']);
    assert.equal(scene.pinned, false);
    scene.click(strip.x + 10, 19);
    assert.equal(scene.pinned, true);
    assert.deepEqual(calendar, ['calendar']);
    // No time, or a notch where it would stand: nothing to click.
    scene.setClock('');
    draw(scene);
    assert.equal(scene.hits.find(h => h.id === 'clock'), undefined);
});

test('the strip with one Provider shows its shortest window left and its longest right', () => {
    const state = {providers: [two().providers[0], off('claudeCode', 'Claude Code'), off('openCode', 'OpenCode')]};
    assert.deepEqual(stripSides(state.providers), {
        left: {provider: 'codex', figure: '76%', pace: 'sustainable'},
        right: {provider: 'codex', figure: '11%', pace: 'tightening'},
    });
});

test('opened, the page draws a card for each Provider that is on and nothing for one that is off', () => {
    const scene = sceneWith(two());
    scene.pin();
    settle(scene);
    const calls = draw(scene);
    const strs = calls.map(c => c.str);
    assert.ok(strs.includes('Codex') && strs.includes('Claude Code'));
    assert.ok(!strs.includes('OpenCode'));
    assert.ok(strs.includes('Weekly') && strs.includes('5 hour'));
    assert.equal(strs.filter(s => s === 'Fresh').length, 2);
});

test('the card hits refresh for its own Provider', () => {
    const scene = sceneWith(two());
    scene.pin();
    settle(scene);
    draw(scene);
    const hit = scene.hits.find(h => h.id === 'refresh:claudeCode');
    assert.ok(hit);
    assert.equal(scene.press(hit.x + 2, hit.y + 2), true);
    assert.deepEqual(scene.clicks, [], 'a button acts on the release, not the press');
    scene.release(hit.x + 3, hit.y + 3);
    assert.deepEqual(scene.clicks, [['refresh', 'claudeCode']]);
    // Let go elsewhere, it does nothing.
    scene.press(hit.x + 2, hit.y + 2);
    scene.release(hit.x - 50, hit.y - 50);
    assert.deepEqual(scene.clicks, [['refresh', 'claudeCode']]);
});

test('with nothing connected the page offers the way to Settings', () => {
    const scene = sceneWith({providers: [off('codex', 'Codex'), off('claudeCode', 'Claude Code'), off('openCode', 'OpenCode')]});
    scene.pin();
    settle(scene);
    const calls = draw(scene);
    assert.ok(calls.some(c => c.str === 'Connect up to two in Settings'));
    const hit = scene.hits.find(h => h.id === 'open-settings');
    assert.ok(hit);
    scene.click(hit.x + 1, hit.y + 1);
    assert.deepEqual(scene.clicks, [['settings']]);
});

test('a Provider that cannot be read says the one thing that fixes it; one a person must act on says No data', () => {
    const scene = sceneWith({
        providers: [
            view('codex', 'Codex', {state: 'disconnected', needsAPersonFirst: true, guidance: 'Install the Codex CLI, then try again.'}),
            off('claudeCode', 'Claude Code'), off('openCode', 'OpenCode'),
        ],
    });
    scene.pin();
    settle(scene);
    const strs = draw(scene).map(c => c.str);
    assert.ok(strs.includes('No data'));
    assert.ok(strs.some(s => s.startsWith('Install the Codex CLI')));
});

test('stale capacity is drawn fainter, and says Stale', () => {
    const state = two();
    state.providers[0].state = 'stale';
    const scene = sceneWith(state);
    scene.pin();
    settle(scene);
    // The gauges are drawn whole and laid down at half strength, as one picture (`.opacity(0.5)`).
    const log = [];
    const cr = new Proxy({}, {get: (_, name) => (...args) => { log.push([name, ...args]); }});
    const text = new RecordingText();
    text.draw = (...args) => { log.push(['text', args[1]]); return RecordingText.prototype.draw.apply(text, args); };
    scene.draw(new Gfx(cr, text), {width: 608, height: 320});
    const calls = text.calls;
    assert.ok(calls.some(c => c.str === 'Stale'));
    // The last: the strip says 76% too.
    const number = log.findLastIndex(c => c[0] === 'text' && c[1] === '76%');
    const opened = log.slice(0, number).findLastIndex(c => c[0] === 'pushGroup');
    const laid = log.slice(number).findIndex(c => c[0] === 'paintWithAlpha');
    assert.ok(opened >= 0 && laid >= 0, 'the gauge number is drawn in a group');
    assert.equal(log[number + laid][1], 0.5, 'and the group is dimmed');
    assert.equal(calls.findLast(c => c.str === '76%').rgba[3], 1, 'inside it, at full strength');
});

test('the closed surface draws no page; the open one fades it in after the shape starts', () => {
    const scene = sceneWith(two());
    assert.ok(!draw(scene).some(c => c.str === 'Codex'));
    scene.pin();
    scene.tick(0);
    scene.tick(0.03);
    assert.ok(!draw(scene).some(c => c.str === 'Codex'), 'a beat behind the shape');
    settle(scene);
    assert.ok(draw(scene).some(c => c.str === 'Codex'));
});

test('the controller opens after three beats of the pointer on the strip, and closes after two away', () => {
    const scene = sceneWith(two());
    let pointer = {x: 304, y: 10};
    const controller = new SurfaceController(scene, {
        pointer: () => pointer, buttons: () => false,
        monitor: () => ({x: 0, y: 0, width: 608, height: 800}), window: () => ({x: 0, y: 0}),
    });
    controller.read();
    controller.read();
    assert.equal(scene.expanded, false, 'a passing pointer has not asked for anything');
    controller.read();
    assert.equal(scene.expanded, true);

    settle(scene);
    pointer = {x: 304, y: 600};
    controller.read();
    assert.equal(scene.expanded, true, 'a pointer that leaves for an instant has not left');
    controller.read();
    assert.equal(scene.expanded, false);
});

test('a pinned surface waits to be dismissed, by Escape or by the focus going', () => {
    const scene = sceneWith(two());
    const controller = new SurfaceController(scene, {
        pointer: () => ({x: 0, y: 700}), buttons: () => false,
        monitor: () => ({x: 0, y: 0, width: 608, height: 800}), window: () => ({x: 0, y: 0}),
    });
    scene.pin();
    for (let i = 0; i < 6; i++)
        controller.read();
    assert.equal(scene.expanded, true);
    assert.equal(controller.key('Escape'), true);
    assert.equal(scene.expanded, false);
    scene.pin();
    controller.focusLost();
    assert.equal(scene.expanded, false);
});

test('the pointer near the closed strip makes the surface grow a little, before it opens', () => {
    const scene = sceneWith(two());
    const pointer = {x: 304, y: 38 + 40};
    const controller = new SurfaceController(scene, {
        pointer: () => pointer, buttons: () => false,
        monitor: () => ({x: 0, y: 0, width: 608, height: 800}), window: () => ({x: 0, y: 0}),
    });
    controller.read();
    assert.equal(scene.pointerNear, true);
    assert.equal(scene.expanded, false);
    settle(scene);
    assert.ok(Math.abs(scene.width.value - 380) < 0.5 && Math.abs(scene.height.value - 42) < 0.5, '410 by 38 to 420 by 42 on a wider notch');
});

test('a button held down on the strip is a drag, not a pointer resting', () => {
    const scene = sceneWith(two());
    const controller = new SurfaceController(scene, {
        pointer: () => ({x: 304, y: 10}), buttons: () => true,
        monitor: () => ({x: 0, y: 0, width: 608, height: 800}), window: () => ({x: 0, y: 0}),
    });
    for (let i = 0; i < 6; i++)
        controller.read();
    assert.equal(scene.expanded, false);
});

test('a swipe carries the pages, a third as far past the end, and one short of forty points settles back', () => {
    const scene = sceneWith(two());
    scene.setModel({pages: ['capacity', 'music']});
    scene.pin();
    settle(scene);
    scene.follow(56);
    assert.ok(Math.abs(scene.stripPosition() - (-0.1 / 3)) < 1e-9, 'past the first page only a third as far');
    scene.settle(30);
    assert.equal(scene.selected, 'capacity');
    settle(scene);
    assert.ok(Math.abs(scene.stripPosition()) < 0.01, 'and back where it was');
    scene.follow(-60);
    scene.settle(-60);
    assert.equal(scene.selected, 'music');
    settle(scene);
    assert.ok(Math.abs(scene.stripPosition() - 1) < 0.01);
});

test('closing, the buttons go back to dots; a row arriving under the closed strip grows the shape on a spring', () => {
    const scene = sceneWith(two());
    scene.setModel({pages: ['capacity', 'music']});
    scene.pin();
    scene.setControlsShown(true);
    scene.focusedPage = 'music';
    settle(scene);
    scene.dismiss();
    assert.equal(scene.controls.target, 0);
    assert.equal(scene.focusedPage, null);
    settle(scene);
    // A wide row under the closed strip: the size moves to it, not jumps.
    scene.compactRow = () => ({height: 40, wide: false, draw: () => {}, module: {id: 'x'}, priority: 1});
    scene.setModel({});
    assert.equal(scene.height.target, 78);
    assert.ok(scene.height.value < 78, 'on its way, not there');
});

test('the near growth does not take over an opening on its way', () => {
    const scene = sceneWith(two());
    scene.pin();
    scene.tick(0);
    scene.tick(0.05);
    const response = scene.height.response;
    scene.setPointerNear(true);
    assert.equal(scene.height.response, response, 'the opening spring keeps the height');
});

test('the shape answers to the pointer where it is going, not where it is drawn', () => {
    const scene = sceneWith(two());
    scene.pin();
    scene.tick(0);
    const target = scene.shapeTargetRect(304);
    assert.equal(target.w, 560);
    assert.ok(scene.shapeRect(304).w < 560);
});

test('rounded rectangles are continuous by default, and a capsule stays a capsule', () => {
    const calls = [];
    const cr = new Proxy({}, {get: (_t, name) => (...a) => calls.push([name, ...a])});
    const g = new Gfx(cr, new RecordingText());
    g.roundRectPath(0, 0, 100, 100, 10);
    assert.deepEqual(calls.find(c => c[0] === 'moveTo').slice(1), [10 * 1.52866483, 0], 'the corner runs 1.53 radii along the side');
    calls.length = 0;
    g.roundRectPath(0, 0, 100, 20, 10);
    assert.deepEqual(calls.find(c => c[0] === 'moveTo').slice(1), [10, 0], 'a capsule\'s ends are half circles');
    calls.length = 0;
    g.roundRectPath(0, 0, 100, 100, 10, {circular: true});
    assert.deepEqual(calls.find(c => c[0] === 'moveTo').slice(1), [10, 0]);
});

test('a group is drawn at full strength and laid down once, faded', () => {
    const calls = [];
    const cr = new Proxy({}, {get: (_t, name) => (...a) => calls.push([name, ...a])});
    const text = new RecordingText();
    const g = new Gfx(cr, text);
    g.withAlpha(0.5, () => g.group(0.5, () => g.drawText('x', 0, 0, {size: 10}, [1, 1, 1])));
    assert.equal(text.calls[0].rgba[3], 1);
    assert.deepEqual(calls.filter(c => c[0] === 'paintWithAlpha'), [['paintWithAlpha', 0.25]]);
});

test('strings: English is the key, and %@ and %d fill in order', () => {
    setDictionary({});
    assert.equal(t('Fresh'), 'Fresh');
    assert.equal(t('%d%% used', 24), '24% used');
    setDictionary({'resets in %@': 'сброс через %@'});
    assert.equal(t('resets in %@', '2 ч'), 'сброс через 2 ч');
    setDictionary({});
});

test('the pointer moving draws again only for what answers to it: a button under it, a press held, a place asked about', () => {
    const scene = sceneWith(two());
    scene.pin();
    settle(scene);
    draw(scene);
    let changes = 0;
    scene.onChange = () => { changes += 1; };
    // Over nothing that answers, it may go anywhere.
    const empty = {x: 2, y: 300};
    assert.equal(scene.hitAt(empty.x, empty.y), null);
    scene.setPointer(empty);
    scene.setPointer({x: 3, y: 301});
    assert.equal(changes, 0);
    // On a button, and off it again: once each.
    const button = scene.hits.find(h => h.onClick);
    scene.setPointer({x: button.x + 1, y: button.y + 1});
    assert.equal(changes, 1);
    assert.equal(scene.hoverId, button.id);
    scene.setPointer({x: button.x + 2, y: button.y + 1});
    assert.equal(changes, 1, 'moving on the same button changes nothing');
    scene.setPointer(empty);
    assert.equal(changes, 2);
    // A press held: every move, for whether it is still on the button.
    scene.press(button.x + 1, button.y + 1);
    changes = 0;
    scene.setPointer({x: button.x + 2, y: button.y + 2});
    assert.equal(changes, 1);
    scene.release(button.x + 2, button.y + 2, {cancel: true});
    // What a drawing asked of the pointer (a Shelf tile lit under it) is asked again when it moves.
    const drawn = scene._draw.bind(scene);
    scene._draw = (g, viewport) => {
        scene.pointerIn(10, 250, 20, 20);
        drawn(g, viewport);
    };
    scene.setPointer(empty);
    draw(scene);
    changes = 0;
    scene.setPointer({x: 11, y: 300});
    assert.equal(changes, 0);
    scene.setPointer({x: 11, y: 251});
    assert.equal(changes, 1, 'into the place asked about');
    // Asked outside a drawing (a swipe looking for its row), nothing is remembered.
    scene.pointerIn(0, 0, 1000, 1000);
    assert.equal(scene._pointerAsked.length, 1);
});

test('Kapa coming under the pointer or leaving it wakes the surface; over her, she follows it on her own frames', () => {
    const scene = sceneWith(two());
    scene.pin();
    settle(scene);
    draw(scene);
    const engine = [...scene.engines.values()][0];
    const f = engine.frame;
    let changes = 0;
    scene.onChange = () => { changes += 1; };
    scene.setShapePointer({x: f.x - 20, y: f.y - 20});
    scene.setShapePointer({x: f.x - 10, y: f.y - 20});
    assert.equal(changes, 0);
    scene.setShapePointer({x: f.x + 2, y: f.y + 2});
    assert.equal(changes, 1, 'she is nudged as it arrives');
    scene.setShapePointer({x: f.x + 8, y: f.y + 4});
    assert.equal(changes, 1);
    // Drawn with it over her, she asks for her next frame a thirtieth of a second on.
    scene.tick(3);
    draw(scene);
    assert.ok(engine.hover);
    assert.ok(Math.abs(scene.kapaDue - (scene.now + 1 / 30)) < 1e-9);
    scene.setShapePointer(null);
    assert.equal(changes, 2, 'and as it leaves');
});

test('a state that changes nothing the scene has is told apart from one that does', () => {
    const scene = sceneWith(two());
    assert.equal(scene.differs(deriveModel(two())), false);
    const changed = two();
    changed.providers[0].windows[0].remainingPercentage = 75;
    assert.equal(scene.differs(deriveModel(changed)), true);
    assert.equal(scene.differs({daemonRunning: false}), true);
    scene.setModel({daemonRunning: false});
    assert.equal(scene.differs({daemonRunning: false}), false);
});

test('Kapa drawn twice in one frame (a shadow, then herself) is stepped once, and keeps moving', () => {
    const scene = new SurfaceScene({barHeight: 38, notchWidth: 0}, {});
    scene.setModel({providers: [], showsKapa: true});
    const g = new Gfx(blackHole(), new RecordingText());
    for (let i = 0; i < 12; i++) {
        scene.tick(1 + i / 30);
        scene.draw(g, {width: 608, height: 320});
        for (let n = 0; n < 2; n++)
            scene.drawKapaAt(g, 'twice', 100, 100, 26, 'listening', {level: 0.9, showsBadge: false, tappable: false});
    }
    assert.ok(scene.engines.get('twice')._mouth > 0.06, `her mouth follows the voice: ${scene.engines.get('twice')._mouth}`);
});

test('the shared springs settle without a step anyone could see', () => {
    // Points per unit: a page is the open width, the strip widens by 190, the buttons grow by 14.
    const cases = [
        [new SurfaceScene({barHeight: 38, notchWidth: 0}, {}).pagePosition, 3, 0.42, 0.8, 560],
        [new SurfaceScene({barHeight: 38, notchWidth: 0}, {}).stripWide, 1, 0.45, 1.0, 190],
        [new SurfaceScene({barHeight: 38, notchWidth: 0}, {}).controls, 1, 0.38, 0.86, 14],
        [new Spring(370, 0.45, 1.0), 560, 0.45, 1.0, 1],
    ];
    for (const [spring, to, response, damping, scale] of cases) {
        spring.to(to, response, damping);
        let last = spring.value;
        for (let i = 0; i < 600 && spring.step(1 / 60); i++)
            last = spring.value;
        // The frame it came to rest in stands at the target; the one before is the step to it.
        assert.ok(Math.abs(last - to) * scale < 0.25, `the last frame was ${Math.abs(last - to) * scale} pt short`);
        assert.equal(spring.value, to);
    }
});

test('a Shelf turned away from no longer claims the row a swipe is over', () => {
    const scene = sceneWith(two());
    scene.scrollableRow = {x: 0, y: 0, w: 600, h: 300, scrollBy: () => {}};
    scene.shelfDropArea = {x: 0, y: 0, w: 10, h: 10};
    scene.expand();
    settle(scene);
    draw(scene);
    assert.equal(scene.scrollableRow, null);
    assert.equal(scene.shelfDropArea, null);
});

test('the strip held down dims both sides as one picture', () => {
    const scene = sceneWith(two());
    const painted = [];
    const cr = new Proxy({}, {get: (_, name) => name === 'paintWithAlpha' ? a => painted.push(a) : () => {}});
    const g = new Gfx(cr, new RecordingText());
    const hit = () => scene.hits.find(h => h.id === 'strip');
    scene.draw(g, {width: 608, height: 320});
    assert.deepEqual(painted, []);
    scene.press(hit().x + 2, hit().y + 2);
    scene.draw(g, {width: 608, height: 320});
    assert.ok(painted.includes(0.6), `${painted}`);
});

/** The hub's state with the words a screen reader is given (`spoken`, view.rs). */
const spokenState = () => {
    const state = two();
    state.providers[0].spoken = 'Codex. Fresh Capacity. 5 hour window, 76 percent left.';
    state.providers[0].windows[0].spoken = '5 hour window, 76 percent left';
    state.providers[0].windows[1].spoken = 'Weekly window, 11 percent left';
    state.providers[1].spoken = 'Claude Code. Fresh Capacity.';
    state.providers[1].windows[0].spoken = '5 hour window, 99 percent left';
    state.providers[1].windows[1].spoken = 'Weekly window, 92 percent left';
    state.strip = {
        left: {provider: 'codex', figure: '76%', pace: 'sustainable', spoken: 'Codex, 5 hour window, 76 percent left'},
        right: {provider: 'claudeCode', figure: '99%', pace: 'sustainable', spoken: 'Claude Code, 5 hour window, 99 percent left'},
    };
    return state;
};

test('a screen reader hears what Swift says: the strip and its sides, each card, each gauge, each button', () => {
    const scene = sceneWith(spokenState());
    draw(scene);
    const closed = scene.accessibleNodes();
    const strip = closed.find(n => n.id === 'strip');
    assert.equal(strip.label, 'Show or hide Capacity details', 'the strip keeps its own words');
    assert.equal(strip.description, 'Codex, 5 hour window, 76 percent left. Claude Code, 5 hour window, 99 percent left');
    const left = closed.find(n => n.id === 'strip:left');
    assert.deepEqual([left.label, left.role], ['Codex, 5 hour window, 76 percent left', 'label']);
    assert.ok(left.x < scene.width.value / 2 + 304 && left.w > 15 && left.h === 38);
    assert.ok(!closed.some(n => n.id.startsWith('card:')), 'the closed surface has no cards to hear');

    scene.pin();
    settle(scene);
    scene.setModel({pages: ['capacity', 'music']});
    scene.setControlsShown(true);
    settle(scene, 4);
    draw(scene);
    const nodes = scene.accessibleNodes();
    const said = id => nodes.find(n => n.id === id);
    assert.deepEqual([said('card:codex').label, said('card:codex').role], ['Codex. Fresh Capacity. 5 hour window, 76 percent left.', 'label']);
    assert.equal(said('gauge:codex:a').label, '5 hour window, 76 percent left');
    assert.equal(said('gauge:claudeCode:b').label, 'Weekly window, 92 percent left');
    assert.deepEqual([said('refresh:codex').label, said('refresh:codex').role], ['Refresh Codex Capacity', 'button']);
    assert.deepEqual([said('page:capacity').role, said('page:capacity').selected, said('page:music').selected], ['tab', true, false]);
    assert.equal(said('page:music').label, 'Music');
    // The card comes before what is in it.
    const order = nodes.map(n => n.id);
    assert.ok(order.indexOf('card:codex') < order.indexOf('refresh:codex') && order.indexOf('refresh:codex') < order.indexOf('gauge:codex:a'));
    // Words only: a card's middle takes no press and lights nothing.
    const card = said('card:codex');
    const gauge = said('gauge:codex:a');
    assert.equal(scene.hitAt(gauge.x + gauge.w / 2, gauge.y + gauge.h / 2), null);
    assert.ok(!scene.hits.some(h => h.id.startsWith('card:') || h.id.startsWith('gauge:') || h.id.startsWith('strip:')));
    assert.equal(scene.click(card.x + card.w / 2, card.y + card.h - 4), false);
});

test('an unread gauge is heard as the card\'s chip; Connect and Open Settings by Swift\'s words, in the language in force', () => {
    const state = two();
    state.providers[0] = view('codex', 'Codex', {state: 'stale', windows: []});
    state.providers[1] = view('claudeCode', 'Claude Code', {state: 'disconnected'});
    const scene = sceneWith(state);
    scene.pin();
    settle(scene);
    draw(scene);
    const nodes = scene.accessibleNodes();
    assert.deepEqual(nodes.filter(n => n.id.startsWith('gauge:codex')).map(n => n.label), ['Stale', 'Stale']);
    assert.equal(nodes.find(n => n.id === 'connect:claudeCode').label, 'Connect this Provider');
    setDictionary({'Connect this Provider': 'Подключить этого провайдера', 'Open Provider Settings': 'Открыть настройки провайдеров'});
    try {
        draw(scene);
        assert.equal(scene.accessibleNodes().find(n => n.id === 'connect:claudeCode').label, 'Подключить этого провайдера');
        const none = sceneWith({providers: [off('codex', 'Codex'), off('claudeCode', 'Claude Code'), off('openCode', 'OpenCode')]});
        none.pin();
        settle(none);
        draw(none);
        const said = none.accessibleNodes();
        assert.equal(said.find(n => n.id === 'open-settings').label, 'Открыть настройки провайдеров');
        assert.deepEqual([said.find(n => n.id === 'marks').label, said.find(n => n.id === 'marks').role], ['Codex, Claude Code, OpenCode', 'label']);
    } finally {
        setDictionary({});
    }
});

test('Tab walks the cards\' buttons, then the page buttons, in the order they are drawn; Return takes one; the ring follows', () => {
    const state = two();
    state.providers[1] = view('claudeCode', 'Claude Code', {state: 'disconnected'});
    const scene = sceneWith(state);
    scene.setModel({pages: ['capacity', 'music']});
    const controller = new SurfaceController(scene, {
        pointer: () => ({x: 0, y: 700}), buttons: () => false,
        monitor: () => ({x: 0, y: 0, width: 608, height: 800}), window: () => ({x: 0, y: 0}),
    });
    scene.pin();
    scene.setControlsShown(true);
    settle(scene, 4);
    draw(scene);
    const walk = [];
    for (let i = 0; i < 5; i++) {
        controller.key('Tab');
        walk.push(scene.focused);
    }
    // In each card top to bottom (`.focusable()` on refresh, then Connect), the cards left to right, then the switcher.
    assert.deepEqual(walk, ['refresh:codex', 'refresh:claudeCode', 'connect:claudeCode', 'page:capacity', 'page:music']);
    assert.equal(scene.focusedPage, 'music');
    assert.equal(controller.key('Tab'), true, 'past the end it leaves them');
    assert.equal(scene.focused, null);
    controller.key('ShiftTab');
    assert.equal(scene.focused, 'page:music', 'Shift-Tab from nothing comes in at the end');
    controller.key('ShiftTab');
    controller.key('ShiftTab');
    assert.equal(scene.focused, 'connect:claudeCode');
    assert.equal(controller.key('Enter'), true);
    assert.deepEqual(scene.clicks.at(-1), ['connect', 'claudeCode']);
    controller.key('ShiftTab');
    controller.key('ShiftTab');
    assert.equal(scene.focused, 'refresh:codex');
    assert.equal(controller.key('Space'), true);
    assert.deepEqual(scene.clicks.at(-1), ['refresh', 'codex']);

    // The ring: the accent, two wide, round the focused control's shape, three out.
    const rings = () => {
        const g = new Gfx(blackHole(), new RecordingText());
        const seen = [];
        g.strokeRoundRect = (x, y, w, h, r, colour, width) => seen.push({x, y, w, h, r, colour, width});
        scene.draw(g, {width: 608, height: 320});
        return seen.filter(s => s.width === 2 && s.colour.length === 3 && s.colour[2] === 1);
    };
    const refresh = scene.hits.find(h => h.id === 'refresh:codex');
    assert.deepEqual(rings().map(({x, y, w, h, r}) => ({x, y, w, h, r})),
        [{x: refresh.x - 2, y: refresh.y - 2, w: refresh.w + 4, h: refresh.h + 4, r: 2}]);
    scene.focused = 'connect:claudeCode';
    const connect = scene.hits.find(h => h.id === 'connect:claudeCode');
    assert.deepEqual(rings().map(({w, h, r}) => ({w, h, r})), [{w: connect.w + 4, h: connect.h + 4, r: connect.h / 2 + 2}]);
    scene.focused = 'page:music';
    const music = scene.hits.find(h => h.id === 'page:music');
    assert.deepEqual(rings().map(({x, y, w, h, r}) => ({x, y, w, h, r})), [{x: music.x - 2, y: music.y - 2, w: 26, h: 26, r: 5}]);
    // Escape still lets the surface go, and the keyboard with it.
    assert.equal(controller.key('Escape'), true);
    assert.equal(scene.expanded, false);
    assert.equal(scene.focused, null);
});

test('with one page there are no page buttons, and Tab still reaches the cards\' buttons', () => {
    const scene = sceneWith(two());
    const controller = new SurfaceController(scene, {
        pointer: () => ({x: 0, y: 700}), buttons: () => false,
        monitor: () => ({x: 0, y: 0, width: 608, height: 800}), window: () => ({x: 0, y: 0}),
    });
    scene.pin();
    settle(scene);
    draw(scene);
    assert.equal(controller.key('Tab'), true);
    assert.equal(scene.focused, 'refresh:codex');
    assert.equal(controller.key('ArrowRight'), false, 'one page has nowhere to turn');
});

test('the page beside the chosen one, drawn while it may come in, is neither heard nor reached by the keyboard', () => {
    const scene = sceneWith(spokenState());
    scene.setModel({pages: ['capacity', 'music']});
    scene.pin();
    scene.select('music');
    settle(scene, 4);
    draw(scene);
    assert.ok(scene.hits.some(h => h.id === 'refresh:codex'), 'the Capacity page is drawn beside it');
    assert.ok(!scene.accessibleNodes().some(n => n.id.startsWith('card:') || n.id.startsWith('refresh:')));
    scene.focusNext(1);
    assert.equal(scene.focused, null, 'nothing on the music page takes the keyboard, and the cards beside it do not');
});

/** A context that writes down every call made of it, and does nothing. */
function recorder() {
    const calls = [];
    return {calls, cr: new Proxy({}, {get: (_t, name) => (...args) => { calls.push([name, ...args]); }})};
}

/** The pictures of their own (`Gfx.isolated`) in a drawing, by their rectangle: the calls of each. */
function isolatedParts(calls) {
    const parts = new Map();
    for (let i = 0; i < calls.length; i++) {
        if (!(calls[i][0] === 'save' && calls[i + 1]?.[0] === 'newPath' && calls[i + 2]?.[0] === 'rectangle'
            && calls[i + 3]?.[0] === 'clip' && calls[i + 4]?.[0] === 'pushGroup'))
            continue;
        let depth = 0, end = i;
        for (; end < calls.length; end++) {
            depth += calls[end][0] === 'save' ? 1 : calls[end][0] === 'restore' ? -1 : 0;
            if (depth === 0)
                break;
        }
        parts.set(JSON.stringify(calls[i + 2].slice(1)), calls.slice(i, end + 1));
        i = end;
    }
    return parts;
}

test('a Kapa on the open page goes on a layer of her own at rest, drawn there as the surface drew her; the surface keeps her tap', () => {
    // Two surfaces alike, open on Capacity and still, their Kapas on the same random stream:
    // one draws everything; the other leaves her to her layer once it has seen where she stands.
    const make = () => {
        const random = Math.random;
        let x = 11;
        Math.random = () => (x = (x * 1103515245 + 12345) % 2147483648) / 2147483648;
        try {
            const scene = sceneWith(two());
            scene.liveLayers = true;
            scene.pin();
            settle(scene, 3);
            scene.draw(new Gfx(blackHole(), new RecordingText()), {width: 608, height: 320});
            return scene;
        } finally {
            Math.random = random;
        }
    };
    const itself = make(), layered = make();
    layered.planLayers();
    const keys = [...layered.layers.keys()];
    assert.equal(keys.length, 1, keys.join());
    const [key] = keys;
    assert.match(key, /^kapa:capacity-card:/);
    const engine = key.slice('kapa:'.length);
    const room = layered.layerRect(key, 304);
    assert.ok(room.y >= 38, 'never over the top bar');

    for (let i = 1; i <= 90; i++) {
        const now = 3 + i / 30;
        itself.tick(now);
        layered.tick(now);
        const one = recorder(), main = recorder(), layer = recorder();
        itself.draw(new Gfx(one.cr, new RecordingText()), {width: 608, height: 320});
        const expected = isolatedParts(one.calls).get(JSON.stringify([room.x, room.y, room.w, room.h]));
        assert.ok(expected, `frame ${i}: drawn by the surface, she is one picture in her room`);
        if (i % 30 === 1) {
            // Now and then the surface is drawn again: she is not on it, and her tap is.
            layered.draw(new Gfx(main.cr, new RecordingText()), {width: 608, height: 320});
            assert.equal(isolatedParts(main.calls).size, 0, `frame ${i}: the surface leaves her out`);
            assert.deepEqual(layered.hits.map(h => h.id), itself.hits.map(h => h.id), 'the same hits, in the same order');
            assert.ok(layered.hits.some(h => h.id === `kapa:${engine}`));
            assert.equal(layered.kapaDue, Infinity, 'and asks for no frame of its own for her');
        }
        layered.drawLayer(key, new Gfx(layer.cr, new RecordingText()), 304);
        assert.deepEqual(isolatedParts(layer.calls).get(JSON.stringify([room.x, room.y, room.w, room.h])), expected,
            `frame ${i}: her layer draws her as the surface did`);
        assert.equal(layered.layers.get(key).due, itself.kapaDue, `frame ${i}: and asks for her frames as the surface did`);
    }

    // She stands somewhere else (her name grew): the surface draws her there, her layer is empty until it is placed again.
    const longer = two();
    longer.providers[0] = {...longer.providers[0], name: 'Codex X'};
    layered.setModel(deriveModel(longer));
    const main = recorder(), layer = recorder();
    layered.draw(new Gfx(main.cr, new RecordingText()), {width: 608, height: 320});
    assert.equal(isolatedParts(main.calls).size, 1, 'the surface draws her');
    layered.drawLayer(key, new Gfx(layer.cr, new RecordingText()), 304);
    assert.equal(isolatedParts(layer.calls).size, 0, 'her layer, nothing');
    layered.planLayers();
    assert.notDeepEqual(layered.layerRect(key, 304), room, 'placed where she stands now');

    // Closing, she goes back to the surface.
    layered.dismiss();
    layered.tick(7);
    layered.planLayers();
    assert.equal(layered.layers.size, 0);
});

test('the control the keyboard is on is the one a screen reader is told is focused', () => {
    const scene = sceneWith(two());
    scene.pin();
    settle(scene);
    draw(scene);
    assert.ok(scene.accessibleNodes().every(n => n.focused === false), 'nothing yet');
    scene.focusNext(1);
    draw(scene);
    const focused = scene.accessibleNodes().filter(n => n.focused);
    assert.equal(focused.length, 1);
    assert.equal(focused[0].id, scene.focused);
    scene.focusNext(1);
    draw(scene);
    assert.deepEqual(scene.accessibleNodes().filter(n => n.focused).map(n => n.id), [scene.focused], 'it moves with Tab');
    scene.dismiss();
    settle(scene);
    draw(scene);
    assert.ok(scene.accessibleNodes().every(n => !n.focused), 'closed, none');
});

// MARK: - The page turn, frame by frame against SwiftUI's spring

/**
 * SwiftUI's `.spring(response:dampingFraction:)` in closed form: where the remainder `x0`
 * (moving at `v0`) stands `t` seconds on, and how fast it goes. ω0 = 2π / response, unit mass.
 */
function swiftSpring(x0, v0, t, response = 0.42, zeta = 0.8) {
    const w0 = 2 * Math.PI / response, wd = w0 * Math.sqrt(1 - zeta * zeta), e = Math.exp(-zeta * w0 * t);
    const b = (v0 + zeta * w0 * x0) / wd;
    const x = e * (x0 * Math.cos(wd * t) + b * Math.sin(wd * t));
    const h = 1e-6;
    const e2 = Math.exp(-zeta * w0 * (t + h));
    const x2 = e2 * (x0 * Math.cos(wd * (t + h)) + b * Math.sin(wd * (t + h)));
    return {x, v: (x2 - x) / h};
}

// Exact while it moves; come to rest, it stands on the page, less than a tenth of a point from the curve's tail.

/** Four pages, open and at rest, on a clock the test keeps (`scene.time`). */
function turning({reduceMotion = false} = {}) {
    const scene = sceneWith(two());
    scene.setModel({pages: ['capacity', 'music', 'teleprompter', 'shelf'], reduceMotion});
    let clock = 5;
    scene.time = () => clock;
    scene.pin();
    for (let i = 0; i < 120; i++)
        scene.tick(clock += 1 / 60);
    // At rest, as the frame chain leaves it: the next frame counts from the motion's start.
    scene._lastNow = null;
    return {scene, at: s => { clock = s; }, now: () => clock};
}

test('a page turns on SwiftUI\'s spring, every frame where the closed form puts it, the first frame included', () => {
    for (const [to, pages] of [['music', 1], ['shelf', 3]]) {
        const {scene, at, now} = turning();
        const start = now() + 0.0071; // between two frames
        at(start);
        scene.select(to);
        for (let frame = 1; frame <= 60; frame++) {
            const t = 0.0042 + (frame - 1) / 60; // the screen's frames, the first 4.2 ms after the click
            scene.tick(start + t);
            const want = pages + swiftSpring(-pages, 0, t).x;
            assert.ok(Math.abs(scene.stripPosition() - want) * 560 < (scene.pagePosition.settled ? 0.1 : 0.001),
                `${pages} page(s), frame ${frame}: ${scene.stripPosition()} for ${want}`);
        }
    }
});

test('a turn taken back mid-flight keeps its speed, as SwiftUI merges springs', () => {
    const {scene, at, now} = turning();
    const start = now();
    at(start);
    scene.select('music');
    for (let t = 1 / 60; t < 0.1; t += 1 / 60)
        scene.tick(start + t);
    // The left arrow 100 ms in, between frames.
    at(start + 0.1);
    const before = swiftSpring(-1, 0, 0.1);
    scene.step(-1);
    assert.equal(scene.selected, 'capacity');
    let last = null;
    for (let t = 0.1 + 1 / 120; t < 1.2; t += 1 / 60) {
        scene.tick(start + t);
        const want = swiftSpring(before.x + 1, before.v, t - 0.1).x;
        assert.ok(Math.abs(scene.stripPosition() - want) * 560 < (scene.pagePosition.settled ? 0.1 : 0.001), `${t}: ${scene.stripPosition()} for ${want}`);
        last = scene.stripPosition();
    }
    // It carried on towards the next page for a moment before it came back: the speed was kept.
    assert.ok(Math.abs(scene.pagePosition.velocity) < 0.01 && Math.abs(last) < 1e-3);
});

test('a swipe hands over to the spring where the fingers left the pages, from still', () => {
    for (const [travel, page, from] of [[-336, 1, 0.6], [-30, 0, 30 / 560], [112, 0, -(112 / 560) / 3]]) {
        const {scene, at, now} = turning();
        scene.follow(0);
        scene.follow(travel);
        assert.ok(Math.abs(scene.stripPosition() - from) < 1e-12, 'the fingers carry the pages, a third as far past an end');
        const start = now();
        scene.settle(travel);
        assert.equal(scene.selected, ['capacity', 'music'][page], 'forty points decide');
        for (let t = 1 / 60; t < 0.8; t += 1 / 60) {
            scene.tick(start + t);
            const want = page + swiftSpring(from - page, 0, t).x;
            assert.ok(Math.abs(scene.stripPosition() - want) * 560 < (scene.pagePosition.settled ? 0.1 : 0.001), `${travel}, ${t}: ${scene.stripPosition()} for ${want}`);
        }
        at(now());
    }
    // Past the last page, the same.
    const {scene, now} = turning();
    scene.select('shelf');
    for (let t = 1 / 60; t < 2; t += 1 / 60)
        scene.tick(now() + t);
    const start = now() + 2;
    scene._lastNow = start;
    scene.follow(-112);
    scene.settle(-112);
    assert.equal(scene.selected, 'shelf');
    scene.tick(start + 0.1);
    assert.ok(Math.abs(scene.stripPosition() - (3 + swiftSpring(0.2 / 3, 0, 0.1).x)) < 1e-6);
});

test('a swipe begun while a turn is still settling leaves the turn to finish under the fingers', () => {
    const {scene, now} = turning();
    const start = now();
    scene.select('music');
    scene.tick(start + 0.2);
    const turning_ = scene.stripPosition();
    // The fingers come down: nothing moves yet (`follow(0)` changes nothing).
    scene.follow(0);
    assert.equal(scene.stripPosition(), turning_);
    scene.follow(-56);
    // Where the fingers put the page, plus what the turn had still to go.
    assert.ok(Math.abs(scene.stripPosition() - (turning_ + 0.1)) < 1e-12);
    scene.tick(start + 0.3);
    assert.ok(Math.abs(scene.stripPosition() - (1.1 + swiftSpring(-1, 0, 0.3).x)) < 1e-9);
});

test('under Reduce Motion a turn is a 0.15 s ease in and out, and the fingers carry nothing', () => {
    const {scene, now} = turning({reduceMotion: true});
    scene.follow(-300);
    assert.equal(scene.stripPosition(), 0);
    const start = now();
    scene.settle(-300);
    assert.equal(scene.selected, 'music');
    const curve = t => { // cubic-bezier(0.42, 0, 0.58, 1), bisected
        let lo = 0, hi = 1;
        for (let i = 0; i < 60; i++) {
            const m = (lo + hi) / 2, x = 3 * 0.42 * m * (1 - m) ** 2 + 3 * 0.58 * m * m * (1 - m) + m ** 3;
            if (x < t) lo = m; else hi = m;
        }
        const s = (lo + hi) / 2;
        return 3 * s * s * (1 - s) + s ** 3;
    };
    for (const t of [0.01, 0.05, 0.075, 0.1, 0.14]) {
        scene.tick(start + t);
        assert.ok(Math.abs(scene.stripPosition() - curve(t / 0.15)) < 1e-4, `${t}`);
    }
    scene.tick(start + 0.15);
    assert.equal(scene.stripPosition(), 1);
    assert.equal(scene.atRest, true);
});

test('the dots change with the turn, on its spring; the arrows at an end and the page shown move nothing', () => {
    const {scene, now} = turning();
    const g = new Gfx(blackHole(), new RecordingText());
    scene.draw(g, {width: 608, height: 320});
    const start = now();
    scene.select('music');
    for (const t of [0.05, 0.1, 0.2, 0.4]) {
        scene.tick(start + t);
        const p = swiftSpring(-1, 0, t).x;
        assert.ok(Math.abs(scene.switcher.get('music').current.value - (1 + p)) < 1e-6);
        assert.ok(Math.abs(scene.switcher.get('capacity').current.value - (-p)) < 1e-6);
    }
    for (let t = 0.4; t < 2; t += 1 / 60)
        scene.tick(start + t);
    assert.equal(scene.atRest, true);
    scene.select('music');
    assert.equal(scene.atRest, true, 'the page shown, chosen again');
    scene.step(-1);
    for (let t = 2; t < 4; t += 1 / 60)
        scene.tick(start + t);
    scene.step(-1);
    assert.equal(scene.atRest, true, 'the left arrow on the first page');
});

test('a turn comes to rest on the page, its last frame a step no one could see', () => {
    const {scene, now} = turning();
    const start = now();
    scene.select('shelf');
    let last = 0, t = 0;
    for (; t < 3 && !scene.atRest; t += 1 / 60) {
        last = scene.stripPosition();
        scene.tick(start + t + 1 / 60);
    }
    assert.equal(scene.stripPosition(), 3);
    assert.ok(Math.abs(last - 3) * 560 < 0.1, `${Math.abs(last - 3) * 560} pt`);
    assert.ok(t > 0.6, 'and not before its tail is under a tenth of a point');
});
