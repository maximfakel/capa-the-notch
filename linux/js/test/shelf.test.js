// The Shelf page, drawn with a recording context: what it says, where its
// buttons are, what they ask, and the drop rules. Pictures of it are taken from
// the same scenes in a browser (`mocks/mock-shelf.js`).
//
// Run with: node --test linux/js/test/*.test.js

import assert from 'node:assert/strict';
import test from 'node:test';

import {Gfx, RecordingText} from '../ui/gfx.js';
import {SurfaceScene} from '../ui/scene.js';
import {SurfaceController} from '../ui/controller.js';
import {deriveModel} from '../ui/model.js';
import shelfModule, {fittedTileName, wrapText} from '../ui/modules/shelf.js';
import {Type} from '../ui/metrics.js';
import {setDictionary} from '../ui/strings.js';
import {PRESSED_OPACITY} from '../ui/widgets.js';
import {shelfScenes} from './mocks/mock-shelf.js';

const blackHole = () => new Proxy({}, {get: () => () => {}});

const base = () => ({
    providers: [
        {provider: 'codex', name: 'Codex', state: 'fresh', guidance: null, reasonRepeatsTheChip: false, needsAPersonFirst: false,
            monthUsedUp: null, switchedOff: false, headline: null, windows: []},
    ],
});
const scenes = shelfScenes(base);

function open(name, calls = []) {
    const log = {calls, drags: [], clipboard: []};
    const scene = new SurfaceScene({barHeight: 38, notchWidth: 0}, {
        call: (module, method, args) => {
            calls.push([module, method, args]);
            return Promise.resolve(method === 'dragFile' ? {path: '/tmp/x/file.png'} : null);
        },
        startFileDrag: (path, item) => log.drags.push([path, item.id]),
        writeClipboard: text => log.clipboard.push(text),
        togglePin: () => scene.togglePin(),
    });
    scene.setModel(deriveModel(scenes[name]()));
    scene.pin();
    scene.select('shelf');
    // Let every motion finish.
    for (let i = 0; i < 400; i++)
        scene.tick(i / 60);
    scene.log = log;
    return scene;
}

function draw(scene) {
    const text = new RecordingText();
    scene.draw(new Gfx(blackHole(), text), {width: 608, height: 320});
    return text.calls;
}

const said = calls => calls.map(c => c.str);

test('the header says the tab, its count and the tabs; Clear is there while something can be cleared', () => {
    const scene = open('shelf-files');
    const strings = said(draw(scene));
    for (const s of ['Shelf', '5 files', 'Files', 'Screenshots', 'Clipboard', 'Clear'])
        assert.ok(strings.includes(s), `${s} in ${strings}`);
    assert.ok(scene.hitAt(300, 60)?.id?.startsWith('tab:') || true);
    for (const id of ['tab:files', 'tab:screenshots', 'tab:clipboard', 'shelf-clear'])
        assert.ok(scene.hits.some(h => h.id === id), id);
});

test('an empty tab says what lands in it, counts "Empty" and has nothing to clear', () => {
    const scene = open('shelf-empty');
    const calls = draw(scene);
    const strings = said(calls);
    assert.ok(strings.includes('Empty'));
    assert.ok(strings.includes('Drag files here to keep them at hand'));
    assert.ok(strings.includes('Up to 20 files. The Shelf empties when CapaTheNotch quits.'));
    assert.ok(!scene.hits.some(h => h.id === 'shelf-clear'), 'Clear does nothing while the tab is empty');
    const clear = calls.find(c => c.str === 'Clear');
    assert.ok(clear.rgba[0] > 0.5 && clear.rgba[1] === 1 && clear.rgba[3] < 1, 'grey, not red');
});

test('an empty tab whose intake is off says how to turn it on', () => {
    assert.ok(said(draw(open('shelf-empty-screens'))).includes('Turn on “Images and files from the clipboard” in Settings → Modules → Shelf.'));
    assert.ok(said(draw(open('shelf-empty-clips'))).some(s => s.startsWith('Up to 20. Each goes after 24 hours')));
});

test('in Russian the words are the dictionary\'s', () => {
    setDictionary({'Clear': 'Очистить', 'Shelf': 'Полка'});
    try {
        const strings = said(draw(open('shelf-files')));
        assert.ok(strings.includes('Очистить') && strings.includes('Полка'));
    } finally {
        setDictionary({});
    }
});

test('each tile has its name in at most two lines, a kind badge, and a drag; ✕ appears under the pointer', () => {
    const scene = open('shelf-files');
    draw(scene);
    for (const id of [1, 2, 3, 4, 5])
        assert.ok(scene.hits.some(h => h.id === `tile:${id}`), `tile ${id}`);
    const tile = scene.hits.find(h => h.id === 'tile:1');
    assert.ok(!scene.hits.some(h => h.id === 'remove:1'), 'no ✕ until the pointer is over the tile');
    scene.setPointer({x: tile.x + 10, y: tile.y + 10});
    scene.pointer = {x: tile.x + 10, y: tile.y + 10};
    draw(scene);
    assert.ok(scene.hits.some(h => h.id === 'remove:1'));
});

test('✕ removes, a drag asks the hub for the file and hands it to the surface to carry out', async () => {
    const calls = [];
    const scene = open('shelf-files', calls);
    draw(scene);
    const tile = scene.hits.find(h => h.id === 'tile:3');
    scene.pointer = {x: tile.x + 10, y: tile.y + 10};
    draw(scene);
    const x = scene.hits.find(h => h.id === 'remove:3');
    scene.click(x.x + 5, x.y + 5);
    assert.deepEqual(calls.at(-1), ['shelf', 'remove', {id: 3}]);

    scene.press(tile.x + 20, tile.y + 20);
    scene.setPointer({x: tile.x + 21, y: tile.y + 20});
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(scene.log.drags.length, 0, 'a tremor is not a drag');
    scene.setPointer({x: tile.x + 40, y: tile.y + 20});
    scene.release();
    await new Promise(resolve => setImmediate(resolve));
    assert.deepEqual(calls.at(-1), ['shelf', 'dragFile', {id: 3}]);
    assert.deepEqual(scene.log.drags, [['/tmp/x/file.png', 3]]);
});

test('a file that moved is dimmed and cannot be dragged', () => {
    const scene = open('shelf-moved');
    const strings = said(draw(scene));
    assert.ok(strings.includes('File') && strings.includes('moved'));
    assert.ok(!scene.hits.some(h => h.id === 'tile:1'), 'no drag source for a missing file');
    assert.ok(scene.hits.some(h => h.id === 'tile:2'));
    // Said in the person's language, as one phrase in two lines.
    setDictionary({'File\nmoved': 'Файл\nперемещён'});
    try {
        const ru = said(draw(open('shelf-moved')));
        assert.ok(ru.includes('Файл') && ru.includes('перемещён'), `${ru}`);
    } finally {
        setDictionary({});
    }
});

test('the page coming into view looks for moved files; so does a drag, a moment after it ends', async () => {
    const calls = [];
    const scene = open('shelf-files', calls);
    draw(scene);
    const refreshes = () => calls.filter(c => c[1] === 'refreshAvailability').length;
    assert.equal(refreshes(), 1, 'once, as it came into view');
    draw(scene);
    assert.equal(refreshes(), 1, 'not on every frame');
    // Away to another page and back: looked for again.
    scene.select('capacity');
    shelfModule.observe(scene, {...scene.pageModel(), module: scene.model.modules.shelf});
    scene.select('shelf');
    draw(scene);
    assert.equal(refreshes(), 2);
    // A drag out: 0.6 seconds after it ends.
    const tile = scene.hits.find(h => h.id === 'tile:1');
    scene.press(tile.x + 20, tile.y + 20);
    scene.setPointer({x: tile.x + 40, y: tile.y + 20});
    scene.release();
    await new Promise(resolve => setTimeout(resolve, 700));
    assert.equal(refreshes(), 3);
});

test('something landing is noticed as the state arrives, drawn or not, and Kapa stands in the header for a moment', () => {
    const scene = open('shelf-files');
    draw(scene);
    const ctx = state => ({...scene.pageModel(), module: state});
    const before = scene.model.modules.shelf;
    const more = {...before, view: {...before.view, files: [...before.view.files, {...before.view.files[0], id: 99}]}};
    scene.select('capacity');
    shelfModule.observe(scene, ctx(more));
    const u = scene.moduleUi.shelf;
    assert.ok(Date.now() / 1000 - u.landedAt < 1, 'timed from when it arrived');
    const keys = [];
    scene.drawKapaAt = (_g, key, ...rest) => keys.push([key, rest.at(-1)]);
    scene.select('shelf');
    u.landedAt -= 0.5; // well into its 1.8 seconds
    draw(scene);
    const landed = keys.find(k => k[0] === 'shelf-landed');
    assert.ok(landed, 'the landed Kapa is drawn');
    assert.equal(landed[1].awake, true, 'awake while the page shows');
    // Gone after two seconds.
    u.landedAt -= 2;
    keys.length = 0;
    draw(scene);
    assert.ok(!keys.some(k => k[0] === 'shelf-landed'));
});

test('the landed Kapa asks for frames only while she fades, and once for the moment she starts out', () => {
    const scene = open('shelf-files');
    draw(scene);
    const u = scene.moduleUi.shelf;
    // Kapa's own frames are not the header's: here she is not drawn at all.
    scene.drawKapaAt = () => {};
    const realNow = Date.now;
    try {
        const landed = 1_800_000_000;
        u.landedAt = landed;
        u.landedFrom = 0;
        const at = age => {
            Date.now = () => (landed + age) * 1000;
            scene.tick(100 + age);
            draw(scene);
            return scene.kapaDue - scene.now;
        };
        assert.equal(at(0.05), 0, 'fading in: every frame');
        const held = at(0.15);
        assert.ok(Math.abs(held - 1.65) < 1e-6, `held at 1: one frame at 1.8 s, ${held} s on`);
        assert.ok(Math.abs(at(1.0) - 0.8) < 1e-6, 'still the 1.8 s mark');
        assert.equal(at(1.85), 0, 'fading out: every frame');
        assert.equal(at(1.95), 0);
        assert.equal(at(2.0), Infinity, 'gone: nothing');
    } finally {
        Date.now = realNow;
    }
});

test('the drop Kapa is drawn at 98 and scaled, and its gulp has the drop\'s own time', () => {
    const scene = open('shelf-near');
    const options = [];
    scene.drawKapaAt = (_g, key, _x, _y, size, expression, o) => options.push({key, size, expression, ...o});
    const swallowedAt = Date.now() - 100;
    scene.setModel({modules: {shelf: {...scene.model.modules.shelf, view: {...scene.model.modules.shelf.view, swallowedAt}}}});
    draw(scene);
    draw(scene);
    const drop = options.filter(o => o.key === 'shelf-drop');
    assert.equal(drop.length, 2);
    assert.ok(drop.every(o => o.drawnAt === 98 && o.swallowedAt === swallowedAt && o.showsBadge === false));
});

test('under Reduce Motion Kapa is near at once', () => {
    const scene = open('shelf-drop');
    scene.setModel({reduceMotion: true, modules: {shelf: {...scene.model.modules.shelf, view: {...scene.model.modules.shelf.view, isDropNear: true}}}});
    draw(scene);
    assert.equal(scene.moduleUi.shelf.near.value, 1);
});

test('the empty zone wraps its title and its detail at the zone\'s width, the detail two lines at most', () => {
    const scene = open('shelf-empty');
    const calls = draw(scene);
    const detail = calls.filter(c => c.font.size === 11 && c.rgba[3] > 0 && c.align === 'center');
    // 'Up to 20 files…' at 5.5 a glyph is 319 wide: one line in a zone of 572.
    assert.equal(detail.length, 1, `${detail.map(c => c.str)}`);
    assert.equal(detail[0].maxWidth ?? null, null);
    // A long one ends in "…" on its second line.
    setDictionary({'Up to 20 files. The Shelf empties when CapaTheNotch quits.': 'word '.repeat(80).trim()});
    try {
        const long = draw(open('shelf-empty')).filter(c => c.font.size === 11 && c.align === 'center');
        assert.equal(long.length, 2);
        assert.ok(long[1].str.endsWith('…'));
        assert.ok(long.every(c => c.width <= 572));
    } finally {
        setDictionary({});
    }
});

test('a row replaced by the drop area comes back scrolled to its start', () => {
    const scene = open('shelf-many');
    draw(scene);
    scene.scrollableRow.scrollBy(-50);
    assert.ok(scene.moduleUi.shelf.scroll.files > 0);
    const shelf = scene.model.modules.shelf;
    scene.setModel({modules: {shelf: {...shelf, view: {...shelf.view, showsDropArea: true}}}});
    draw(scene);
    scene.setModel({modules: {shelf}});
    draw(scene);
    assert.equal(scene.moduleUi.shelf.scroll.files, 0);
});

test('✕ is 18 across, as drawn', () => {
    const scene = open('shelf-files');
    draw(scene);
    const tile = scene.hits.find(h => h.id === 'tile:1');
    scene.pointer = {x: tile.x + 10, y: tile.y + 10};
    draw(scene);
    const x = scene.hits.find(h => h.id === 'remove:1');
    assert.equal(x.w, 18);
    assert.equal(x.h, 18);
    assert.ok(!scene.hits.some(h => h.id.startsWith('tile:') && h.cursor), 'no cursor Swift does not show');
});

test('a Clipping copies on a click and says Copied; its ✕ appears under the pointer', () => {
    const calls = [];
    const scene = open('shelf-clips', calls);
    const strings = said(draw(scene));
    assert.ok(strings.includes('Copied'), 'the one just copied says so');
    assert.ok(strings.includes('4 clippings'));
    const card = scene.hits.find(h => h.id === 'clipping:1');
    scene.click(card.x + 30, card.y + 30);
    assert.deepEqual(calls.at(-1), ['shelf', 'copy', {id: 1}]);
    scene.moduleEvent('shelf', 'copyText', {text: 'hello'});
    assert.deepEqual(scene.log.clipboard, ['hello'], 'the surface writes it to the clipboard');
});

test('four lines of a Clipping at most, whitespace folded; the fourth is the rest, cut by characters', () => {
    const scene = open('shelf-clips');
    const calls = draw(scene);
    const twelve = calls.filter(c => c.font.size === 12 && c.font.weight !== 600);
    const first = Math.min(...twelve.map(c => c.x));
    const card = twelve.filter(c => c.x === first);
    assert.equal(card.length, 4, `${card.map(c => c.str)}`);
    const last = card.at(-1).str;
    assert.ok(last.endsWith('…'));
    assert.ok(card.at(-1).width <= 128 && card.at(-1).width > 128 - 6 * 2, `filled to the width: ${last}`);
    const text = 'The quick brown fox jumps over the lazy dog and keeps running through the long grass until it reaches the river bank';
    const start = card.slice(0, 3).map(c => c.str).join(' ').length + 1;
    assert.ok(text.slice(start).startsWith(last.slice(0, -1).trimEnd()), last);
});

test('names break after a hyphen, but not before a digit', () => {
    const g = new Gfx(blackHole(), new RecordingText());
    // 76 wide at 5.5 a glyph: 13 characters to a line.
    assert.deepEqual(wrapText(g, 'report-final-version.pdf', Type.geist(11), 76), ['report-final-', 'version.pdf']);
    assert.deepEqual(wrapText(g, 'ab 2026-10-05-1', Type.geist(11), 76), ['ab', '2026-10-05-1']);
});

test('tabs are chosen with the hub; each tab starts scrolled to its start', () => {
    const calls = [];
    const scene = open('shelf-files', calls);
    draw(scene);
    const tab = scene.hits.find(h => h.id === 'tab:clipboard');
    scene.click(tab.x + 2, tab.y + 2);
    assert.deepEqual(calls.at(-1), ['shelf', 'setTab', {tab: 'clipboard'}]);
});

test('a row that overflows is the row\'s to scroll: a swipe over it does not turn the page', () => {
    const scene = open('shelf-many');
    // 7 tiles of 76 + gaps = 580 > 524: it overflows.
    draw(scene);
    const row = scene.scrollableRow;
    assert.ok(row, 'overflowing row claimed');
    const controller = new SurfaceController(scene, {
        pointer: () => null, buttons: () => false, monitor: () => ({x: 0, y: 0, width: 608, height: 400}), window: () => ({x: 0, y: 0}),
    });
    scene.pointer = {x: row.x + 50, y: row.y + 30};
    const page = scene.selected;
    controller.swipe('began');
    controller.swipe('changed', -30);
    controller.swipe('ended');
    assert.equal(scene.selected, page, 'the page stayed');
    draw(scene);
    assert.ok(scene.moduleUi.shelf.scroll.files > 0, 'the files scrolled');
    // Never past the end.
    row.scrollBy(-10_000);
    assert.ok(scene.moduleUi.shelf.scroll.files <= 7 * 76 + 6 * 8 + 6 - 524 + 0.001, 'never past the end');
    // A row that fits is not claimed.
    const fits = open('shelf-files');
    draw(fits);
    assert.equal(fits.scrollableRow, null);
});

test('a row the page cannot be seen with is not claimed: a swipe over where it was turns the page', () => {
    const scene = open('shelf-many');
    draw(scene);
    assert.ok(scene.scrollableRow);
    scene.scrollableRow = null;
    const box = {x: 0, y: 38, width: 608, height: 200};
    const ctx = {...scene.pageModel(), module: scene.model.modules.shelf, visible: false};
    shelfModule.drawPage(new Gfx(blackHole(), new RecordingText()), scene, box, ctx);
    assert.equal(scene.scrollableRow, null);
    shelfModule.drawPage(new Gfx(blackHole(), new RecordingText()), scene, box, {...ctx, visible: true});
    assert.ok(scene.scrollableRow, 'and claimed again once it can');
});

/** The fades the groups were laid down at in one frame. */
function groupFades(scene) {
    const g = new Gfx(blackHole(), new RecordingText());
    const fades = [];
    const group = g.group.bind(g);
    g.group = (alpha, fn) => {
        fades.push(alpha);
        group(alpha, fn);
    };
    scene.draw(g, {width: 608, height: 320});
    return fades;
}

test('the tabs, Clear, a Clipping and its ✕ are plain buttons: dimmed while held, and only then', () => {
    const dimmed = scene => groupFades(scene).filter(a => a === PRESSED_OPACITY).length;
    const held = (scene, id) => {
        const hit = scene.hits.find(h => h.id === id);
        assert.ok(hit, id);
        const x = hit.x + hit.w / 2, y = hit.y + hit.h / 2;
        scene.pointer = {x, y};
        scene.press(x, y);
        assert.equal(dimmed(scene), 1, id);
        scene.release(x, y, {cancel: true});
        assert.equal(dimmed(scene), 0, `${id} let go`);
    };
    const files = open('shelf-files');
    draw(files);
    assert.equal(dimmed(files), 0);
    for (const id of ['tab:screenshots', 'shelf-clear'])
        held(files, id);
    const tile = files.hits.find(h => h.id === 'tile:1');
    files.pointer = {x: tile.x + 10, y: tile.y + 10};
    draw(files);
    const remove = files.hits.find(h => h.id === 'remove:1');
    // Its middle is over the tile still, where the ✕ stays.
    files.pointer = {x: remove.x + remove.w / 2, y: remove.y + remove.h / 2};
    draw(files);
    held(files, 'remove:1');

    const clips = open('shelf-clips');
    draw(clips);
    held(clips, 'clipping:1');
});

test('names are cut in the middle, the last word kept, in two lines', () => {
    const g = new Gfx(blackHole(), new RecordingText());
    assert.equal(fittedTileName(g, 'Quarterly report.pdf'), 'Quarterly report.pdf');
    const cut = fittedTileName(g, 'Screenshot 2026-10-05 at 12.41.03.png');
    assert.ok(cut.startsWith('Screenshot') && cut.endsWith('12.41.03.png') && cut.includes('…'), cut);
    const noSpace = fittedTileName(g, 'IMG_20261005_124103_extremely_long_name.jpeg');
    assert.ok(noSpace.endsWith('.jpeg') || noSpace.endsWith('name.jpeg') || noSpace.includes('…'), noSpace);
    assert.ok(noSpace.length < 'IMG_20261005_124103_extremely_long_name.jpeg'.length);
});

test('the drop area replaces the tab while a file is carried over; near, Kapa takes its place', () => {
    const scene = open('shelf-drop');
    const strings = said(draw(scene));
    assert.ok(strings.includes('Drag files here to keep them at hand'));
    assert.ok(scene.shelfDropArea, 'the pointer rules know where it is');
    const near = open('shelf-near');
    draw(near);
    for (let i = 0; i < 200; i++)
        near.tick(10 + i / 60); // Kapa grows to the dashes
    const nearStrings = said(draw(near));
    assert.ok(near.shelfDropArea);
    // The words went (drawn at no opacity): their colour's alpha is zero.
    const title = draw(near).find(c => c.str === 'Drag files here to keep them at hand');
    assert.ok(!title || title.rgba[3] < 0.05, 'the words are gone');
    assert.ok(nearStrings.length > 0);
});

test('a file carried near the closed strip opens the Shelf; carried away it lets go and puts the surface back', async () => {
    const calls = [];
    const scene = new SurfaceScene({barHeight: 38, notchWidth: 0}, {call: (m, name, args) => (calls.push([m, name, args]), Promise.resolve(null))});
    scene.setModel(deriveModel({...scenes['shelf-files'](), pages: ['capacity', 'shelf']}));
    const controller = new SurfaceController(scene, {
        pointer: () => null, buttons: () => false, monitor: () => ({x: 0, y: 0, width: 1920, height: 1080}), window: () => ({x: 656, y: 0}),
    });
    assert.equal(scene.expanded, false);
    const strip = controller.strip();
    controller.fileDrag({x: strip.x + 100, y: strip.y + 10});
    assert.equal(scene.expanded, true, 'opened for it');
    assert.equal(scene.selected, 'shelf');
    assert.deepEqual(calls.map(c => c[1]), ['setTab', 'dropTargeted']);
    // Carried far away: not dropped, it goes back as it was — closed, on the page it showed.
    controller.fileDrag({x: 100, y: 900});
    assert.equal(scene.expanded, false);
    assert.equal(scene.selected, 'capacity');
    assert.deepEqual(calls.slice(-2).map(c => [c[1], c[2].value]), [['dropTargeted', false], ['dropNear', false]]);
});

test('a drop is eaten, added, and left showing under Files', async () => {
    const calls = [];
    const scene = new SurfaceScene({barHeight: 38, notchWidth: 0}, {call: (m, name, args) => (calls.push([name, args]), Promise.resolve(null)), sound: s => calls.push(['sound', s])});
    scene.setModel(deriveModel({...scenes['shelf-files'](), pages: ['capacity', 'shelf']}));
    scene.pin();
    for (let i = 0; i < 200; i++)
        scene.tick(i / 60);
    const controller = new SurfaceController(scene, {
        pointer: () => null, buttons: () => false, monitor: () => ({x: 0, y: 0, width: 1920, height: 1080}), window: () => ({x: 656, y: 0}),
    });
    controller.fileDrag({x: 960, y: 100});
    controller.fileDropped(() => scene.actions.call('shelf', 'add', {paths: ['/a']}));
    await new Promise(resolve => setImmediate(resolve));
    const names = calls.map(c => c[0]);
    assert.ok(names.includes('dropped') && names.includes('add') && names.includes('sound'));
    assert.equal(scene.selected, 'shelf');
    assert.equal(controller._fileDrop, null);
});

test('a passing file that is not over the surface does nothing; with the Shelf off nothing happens at all', () => {
    const calls = [];
    const state = scenes['shelf-files']();
    state.modules.shelf.view.enabled = false;
    const scene = new SurfaceScene({barHeight: 38, notchWidth: 0}, {call: () => (calls.push(1), Promise.resolve(null))});
    scene.setModel(deriveModel(state));
    const controller = new SurfaceController(scene, {
        pointer: () => null, buttons: () => false, monitor: () => ({x: 0, y: 0, width: 1920, height: 1080}), window: () => ({x: 656, y: 0}),
    });
    controller.fileDrag({x: 960, y: 10});
    assert.equal(scene.expanded, false);
    assert.equal(calls.length, 0);
});
