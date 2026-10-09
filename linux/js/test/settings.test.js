// Run with: node --test linux/js/test/*.test.js
// The Settings page against what the hub and the Rust module say they have
// (`settings/fixtures/state.json`, written by `cargo test -p capa-settings fixture`).
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';

import {
    CONSENT, DICTATION_PAGES, MODULES, MODULE_CONTRACT, MODULE_SWITCH, ONBOARDING_STEPS, SECTIONS, SHELF_IMAGES, SHELF_TEXT,
    accessRows, bindings, blocksFor, capturePossible, get, providerNote, providerStatus, refreshLabel, teleprompterRows,
} from '../settings/schema.js';
import {settingsQuery, settingsTarget} from '../settings/target.js';
import {EXTRA_RU} from '../settings/strings-extra.js';
import {setDictionary} from '../ui/strings.js';

const fixture = JSON.parse(readFileSync(new URL('../settings/fixtures/state.json', import.meta.url)));
const source = name => readFileSync(new URL(`../settings/${name}`, import.meta.url), 'utf8');
const KEYS = fixture.keys, COMMANDS = fixture.commands;

/** A whole hub state around the module's. */
const hub = (settings, extra = {}) => ({
    providers: ['codex', 'claudeCode', 'openCode'].map(p => ({provider: p, state: 'fresh', capturedAt: 0})),
    displays: {displays: [{id: 1, name: 'Built-in display'}, {id: 2, name: 'Second'}]},
    modules: {settings, dictation: {modelReady: true}, teleprompter: {captureExclusion: 'unsupported', shortcuts: []}},
    ...extra,
});

const keyKnown = key => KEYS.includes(key) || (key.endsWith('.') && KEYS.includes(key));

for (const scene of ['quiet', 'busy']) {
    test(`every row of every section binds to a key, command and path that exist (${scene})`, () => {
        const settings = fixture[scene];
        const state = hub(settings);
        for (const section of SECTIONS.filter(s => s.id !== 'modules')) {
            const found = bindings(blocksFor(section.id, state, settings));
            for (const key of found.keys)
                assert.ok(keyKnown(key), `${section.id}: key ${key} is not one the module takes`);
            for (const command of found.commands)
                assert.ok(COMMANDS.includes(command), `${section.id}: command ${command}`);
            for (const path of found.paths)
                assert.notEqual(get(settings, path), undefined, `${section.id}: path ${path} is not in the state`);
        }
    });
}

test('the Modules, the Teleprompter card and the Shelf card bind to what exists', () => {
    const settings = fixture.busy;
    for (const m of MODULES) {
        const sw = MODULE_SWITCH[m.id];
        assert.ok(KEYS.includes(sw.key), sw.key);
        assert.equal(typeof get(settings, sw.path), 'boolean', sw.path);
    }
    for (const spec of [SHELF_IMAGES, SHELF_TEXT]) {
        assert.ok(KEYS.includes(spec.key), spec.key);
        assert.equal(typeof get(settings, spec.path), 'boolean', spec.path);
    }
    const rows = teleprompterRows(hub(settings), settings);
    const found = bindings(rows);
    for (const key of found.keys)
        assert.ok(keyKnown(key), key);
    for (const command of found.commands)
        assert.ok(COMMANDS.includes(command), command);
    for (const path of found.paths)
        assert.notEqual(get(settings, path), undefined, path);
    assert.equal(rows.shortcuts.length, 4);
    for (const shortcut of rows.shortcuts)
        assert.ok(settings.teleprompter.shortcuts[shortcut.id], shortcut.id);
});

test('what the page sends the module is a command and a key the module has', () => {
    const page = source('page.js') + source('schema.js');
    const commands = new Set([
        ...[...page.matchAll(/this\.command\('(\w+)'/g)].map(m => m[1]),
        ...[...page.matchAll(/command: '(\w+)'/g)].map(m => m[1]),
        ...[...page.matchAll(/'settings', '(\w+)'/g)].map(m => m[1]),
    ]);
    assert.ok(commands.size > 5);
    for (const command of commands)
        assert.ok(COMMANDS.includes(command), `settings.${command}`);
    const keys = new Set([
        ...[...page.matchAll(/this\.set\('([A-Za-z.]+)'/g)].map(m => m[1]),
        ...[...page.matchAll(/\bkey: '([A-Za-z.]+)'/g)].map(m => m[1]),
    ]);
    assert.ok(keys.size > 15);
    for (const key of keys)
        assert.ok(keyKnown(key), `settings.set ${key}`);
    // Only the names the Modules answer reach them.
    const toModules = [...page.matchAll(/host\.call\('(dictation|teleprompter)', '(\w+)'/g)].map(m => [m[1], m[2]]);
    for (const [module, method] of toModules) {
        const known = module === 'dictation'
            ? [...MODULE_CONTRACT.dictation.commands, ...MODULE_CONTRACT.dictation.optionalCommands]
            : MODULE_CONTRACT.teleprompter.commands;
        assert.ok(known.includes(method), `${module}.${method}`);
    }
});

test('every sentence the page says has a Russian one, unless the Swift never said it either', () => {
    const russian = {...fixture.dictionaryRu, ...EXTRA_RU};
    const said = new Set();
    for (const scene of ['quiet', 'busy']) {
        const settings = fixture[scene];
        const state = hub(settings);
        const walk = node => {
            if (!node || typeof node !== 'object')
                return;
            if (Array.isArray(node))
                return node.forEach(walk);
            if (node.literal)
                return;
            for (const [k, v] of Object.entries(node)) {
                if (typeof v === 'string' && ['title', 'footnote', 'subtitle', 'name', 'summary', 'reason', 'note'].includes(k))
                    said.add(v);
                else if (v && typeof v === 'object')
                    walk(v);
            }
        };
        for (const s of SECTIONS.filter(x => x.id !== 'modules'))
            walk(blocksFor(s.id, state, settings));
        walk(teleprompterRows(state, settings));
        walk(accessRows(state, 'linux'));
        walk(accessRows(state, 'windows'));
    }
    for (const s of SECTIONS) { said.add(s.title); said.add(s.subtitle); }
    for (const m of MODULES) { said.add(m.name); said.add(m.summary); }
    for (const s of ONBOARDING_STEPS) { said.add(s.name); said.add(s.title); said.add(s.subtitle); }
    for (const c of Object.values(CONSENT)) { said.add(c.title); said.add(c.body); }
    for (const p of Object.values(DICTATION_PAGES)) { said.add(p.title); said.add(p.subtitle); }
    for (const spec of [SHELF_IMAGES, SHELF_TEXT]) { said.add(spec.title); said.add(spec.note); }
    for (const m of [...source('page.js').matchAll(/\bt\('((?:[^'\\]|\\.)+)'/g)])
        said.add(m[1].replace(/\\'/g, "'").replace(/\\n/g, '\n'));

    // Words the macOS-only rows say for another system are said by the page, not translated here.
    // Names, and sentences already made of a format and its number (their key is the format).
    // The music note's short English form is said only in English: the Russian is the Swift's own whole sentence.
    const allowed = new Set(['%@', '%d', 'CapaTheNotch', 'English', 'Second', 'Open, the surface has a page for it.']);
    const missing = [...said].filter(s => s && !allowed.has(s) && !(s in russian) && !/^Every \d+ minutes$/.test(s) && /[A-Za-z]{3}/.test(s)).sort();
    // The sentences the page adds for other systems have entries of their own in EXTRA_RU; anything
    // else missing is a Swift sentence the table lacks and must be looked at.
    assert.deepEqual(missing, [], `no Russian for:\n${missing.join('\n')}`);
});

test('where Settings opens from: a card, the strip, Edit Script, Dictation', () => {
    assert.deepEqual(settingsTarget(null), {}, 'the menu asks for no section: a new window opens on General, an open one stays');
    assert.deepEqual(settingsTarget(undefined), {});
    assert.equal(settingsQuery(null), '');
    assert.deepEqual(settingsTarget('providers'), {section: 'providers'});
    assert.deepEqual(settingsTarget('modules'), {section: 'modules'}, 'Edit Script opens Modules, its cards as they were');
    assert.deepEqual(settingsTarget('dictation'), {section: 'modules', module: 'dictation', page: 'auto'});
    assert.equal(settingsQuery('dictation'), 'section=modules&module=dictation&page=auto');
});

test('a Provider\'s line: off, fresh, stale, disconnected; and why a switch waits', () => {
    const fmt = {ago: () => '2 minutes ago', clock: () => '3:30 PM'};
    assert.deepEqual(providerStatus(false, null, 0, fmt), {tint: 'muted', line: 'Off'});
    assert.deepEqual(providerStatus(true, {state: 'fresh', capturedAt: 1}, 0, fmt), {tint: 'green', line: 'Fresh · read 2 minutes ago'});
    assert.deepEqual(providerStatus(true, {state: 'stale', capturedAt: 1}, 0, fmt), {tint: 'yellow', line: 'Stale · last read at 3:30 PM'});
    assert.deepEqual(providerStatus(true, {state: 'disconnected'}, 0, fmt), {tint: 'red', line: 'Disconnected'});
    assert.deepEqual(providerStatus(true, {state: 'connecting'}, 0, fmt), {tint: 'muted', line: 'Connecting'});
    assert.deepEqual(providerStatus(true, undefined, 0, fmt), {tint: 'muted', line: 'Connecting'});

    assert.equal(providerNote(false, false, null), 'Turn one off to turn this on.');
    assert.equal(providerNote(false, true, null), null);
    assert.equal(providerNote(true, true, {state: 'fresh', guidance: 'x'}), null);
    assert.equal(providerNote(true, true, {state: 'stale', guidance: 'Retrying.'}), 'Retrying.');
    assert.equal(providerNote(true, false, {state: 'disconnected', guidance: 'Sign in.'}), 'Sign in.', 'on stays on');
});

test('the refresh paces read as the Swift says them', () => {
    assert.equal(refreshLabel(60), 'Every 1 minutes');
    assert.equal(refreshLabel(300), 'Every 5 minutes');
    assert.equal(refreshLabel(900), 'Every 15 minutes');
    assert.equal(refreshLabel(3600), 'Every hour');
});

test('Russian words come from the dictionary the hub sends', () => {
    setDictionary(fixture.dictionaryRu);
    assert.equal(refreshLabel(300), 'Каждые 5 мин');
    setDictionary({});
});

test('what cannot be kept out of a recording is said, where the switch is', () => {
    const settings = fixture.quiet;
    const linux = hub(settings);
    assert.equal(capturePossible(linux, settings), false);
    const general = blocksFor('general', linux, settings);
    assert.match(general[0].footnote, /GNOME has no way/);
    assert.match(general[0].footnote, /Teleprompter/);
    assert.equal(general[0].rows.find(r => r.key === 'screenSharingAllowed').disabled, true);

    const windows = hub({...settings, platform: 'windows'});
    windows.modules.teleprompter.captureExclusion = 'supported';
    assert.equal(capturePossible(windows, windows.modules.settings), true);
    const there = blocksFor('general', windows, windows.modules.settings);
    assert.match(there[0].footnote, /^macOS keeps CapaTheNotch out of the capture/);
    assert.equal(there[0].rows.find(r => r.key === 'screenSharingAllowed').disabled, false);
});

test('the permissions say what each system asks, and follow the Dictation Module', () => {
    const linux = accessRows(hub(fixture.quiet), 'linux');
    assert.deepEqual(linux.map(r => r.id), ['notifications', 'microphone', 'insertion']);
    assert.equal(linux.find(r => r.id === 'microphone').state, 'granted', 'a native program needs no permission to listen');
    const asking = hub(fixture.quiet);
    asking.modules.dictation = {microphoneAllowed: false, insertionAllowed: false};
    const windows = accessRows(asking, 'windows');
    assert.equal(windows.find(r => r.id === 'microphone').state, 'notAsked');
    asking.modules.dictation = {microphoneAllowed: true, insertionAllowed: true};
    assert.equal(accessRows(asking, 'windows').every(r => r.state === 'granted'), true);
    // Accessibility, as the Swift names it; with no host that can paste there is nothing to ask for.
    asking.modules.dictation = {microphoneAllowed: true, insertionAllowed: false};
    const insertion = accessRows(asking, 'linux').find(r => r.id === 'insertion');
    assert.equal(insertion.name, 'Accessibility');
    assert.equal(insertion.state, 'unavailable');
    asking.modules.dictation = {};
    assert.equal(accessRows(asking, 'linux').find(r => r.id === 'insertion').state, 'notAsked');
});

test('the words the page adds are said in Russian once, and none the hub already has', () => {
    for (const key of Object.keys(EXTRA_RU))
        assert.ok(!(key in fixture.dictionaryRu), `${key} is in ru.rs already`);
});

test('onboarding has the Swift\'s six steps in its order, and Settings its five sections', () => {
    assert.deepEqual(ONBOARDING_STEPS.map(s => s.id), ['welcome', 'permissions', 'providers', 'music', 'teleprompter', 'dictation']);
    assert.deepEqual(SECTIONS.map(s => s.id), ['general', 'providers', 'alerts', 'modules', 'diagnostics']);
    assert.deepEqual(MODULES.map(m => m.id), ['music', 'teleprompter', 'dictation', 'shelf']);
});

test('the alert rows of the Providers wait on the global switch', () => {
    const off = {...fixture.quiet, alertsEnabled: false};
    const rows = blocksFor('alerts', hub(off), off)[0].rows.filter(r => r.keyPrefix);
    assert.equal(rows.length, 3);
    assert.ok(rows.every(r => r.disabled === true));
    const on = {...fixture.quiet, alertsEnabled: true};
    assert.ok(blocksFor('alerts', hub(on), on)[0].rows.filter(r => r.keyPrefix).every(r => r.disabled === false));
});

test('Swift\'s picks: the languages name themselves, the displays start with the built-in one', () => {
    const settings = fixture.quiet;
    const general = blocksFor('general', hub(settings), settings)[0].rows;
    const language = general.find(r => r.key === 'language').options.map(o => o.title);
    assert.deepEqual(language, ['System', 'English', 'Русский']);
    const display = general.find(r => r.key === 'displayId').options;
    assert.deepEqual(display.map(o => o.id), [0, 1, 2]);
});

test('the Teleprompter\'s shortcuts the hub could not take are said under their titles', () => {
    const settings = fixture.busy;
    const state = hub(settings);
    state.modules.teleprompter.unavailable = ['stop'];
    const rows = teleprompterRows(state, settings);
    assert.deepEqual(rows.shortcuts.filter(s => s.unavailable).map(s => s.id), ['stop']);
    delete state.modules.teleprompter.unavailable;
    state.modules.teleprompter.shortcuts = [{action: 'faster', unavailable: true}];
    assert.deepEqual(teleprompterRows(state, settings).shortcuts.filter(s => s.unavailable).map(s => s.id), ['faster']);
});

/** Just enough of a document for the page to say there is no hub (the page needs no more without one). */
function hublessDocument(posted) {
    class Element {
        constructor(tag) {
            Object.assign(this, {tagName: tag, nodeType: 1, children: [], dataset: {}, style: {}, attributes: {}, textContent: '', className: ''});
            this.classList = {toggle() {}, add() {}, remove() {}, contains: () => false};
        }

        append(...nodes) { this.children.push(...nodes); }
        replaceChildren(...nodes) { this.children = nodes; }
        querySelector() { return null; }
        querySelectorAll() { return []; }
        contains() { return false; }
        addEventListener() {}
        setAttribute(k, v) { this.attributes[k] = v; }
        remove() {}
    }
    globalThis.document = {
        createElement: tag => new Element(tag), createTextNode: text => ({nodeType: 3, textContent: text}),
        body: new Element('body'), documentElement: new Element('html'), activeElement: null, addEventListener() {},
    };
    globalThis.window = {
        addEventListener() {}, dispatchEvent() {}, matchMedia: () => ({matches: false}),
        webkit: {messageHandlers: {capa: {postMessage: m => posted.push(JSON.parse(m))}}},
    };
    globalThis.getComputedStyle = () => ({backgroundColor: 'rgb(0, 0, 0)'});
    // A state arriving asks for a frame to draw in; the test draws when it says.
    globalThis.requestAnimationFrame = () => 0;
    globalThis.cancelAnimationFrame = () => {};
    globalThis.CustomEvent = class { constructor(type, options) { this.type = type; this.detail = options?.detail; } };
    globalThis.location = {href: 'file:///capa/settings/index.html', search: ''};
    return Element;
}

test('without capa-daemon the page says so in the language last chosen, which the program hints with the null state', async () => {
    const posted = [];
    const names = ['document', 'window', 'getComputedStyle', 'CustomEvent', 'location', 'requestAnimationFrame', 'cancelAnimationFrame'];
    const kept = new Map(names.filter(n => n in globalThis).map(n => [n, globalThis[n]]));
    const Element = hublessDocument(posted);
    // The window reads the clock every half minute; that beat is not to keep the test running.
    const every = globalThis.setInterval;
    globalThis.setInterval = (fn, ms) => every(fn, ms).unref();
    try {
        const {webkitHost} = await import('../settings/host-webkit.js');
        const {spokenLanguage, start} = await import('../settings/page.js');
        const host = webkitHost();
        assert.deepEqual(posted, [{kind: 'ready'}]);
        // What settings-app.js sends when GetState has no answer: null, and the stored language.
        window.__capaState('null', JSON.stringify({language: 'ru'}));
        await host.ready;
        assert.equal(host.state(), null, 'still no state: nothing reads the hint as one');
        assert.equal(spokenLanguage(host), 'ru');
        const root = new Element('div');
        start(root, host);
        assert.equal(root.children.length, 1);
        assert.equal(root.children[0].className, 'hubless');
        assert.equal(root.children[0].textContent, 'capa-daemon не запущен. Запустите его и откройте настройки снова.');
        assert.equal(document.documentElement.lang, 'ru');
        // Null with no hint, as before: English.
        window.__capaState('null');
        assert.equal(host.hint(), null);
        start(root, host);
        assert.equal(root.children[0].textContent, 'capa-daemon is not running. Start it, then reopen Settings.');
        // A state that comes is the state, and its own language rules; the hint is gone.
        window.__capaState('null', JSON.stringify({language: 'ru'}));
        window.__capaState(JSON.stringify({language: 'en'}));
        assert.equal(host.hint(), null);
        assert.equal(spokenLanguage(host), 'en');
    } finally {
        setDictionary({});
        globalThis.setInterval = every;
        // Node's own (its CustomEvent) are put back; the rest were never there.
        for (const name of names) {
            if (kept.has(name))
                globalThis[name] = kept.get(name);
            else
                delete globalThis[name];
        }
    }
});

test('the GNOME settings program pushes the stored language with the null state', () => {
    const app = readFileSync(new URL('../../gnome-extension/capa-the-notch@capathenotch.tech/settings-app.js', import.meta.url), 'utf8');
    assert.match(app, /const hint = state \? '' : `, \$\{JSON\.stringify\(JSON\.stringify\(\{language: storedLanguage\(\)\}\)\)\}`;/);
    assert.match(app, /window\.__capaState\(\$\{JSON\.stringify\(JSON\.stringify\(state\)\)\}\$\{hint\}\)/);
});
