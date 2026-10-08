// Settings and onboarding, as data. One description, read by the page that
// both windows run (`page.js`): what the Swift views are, row for row — their
// words, their order, what is disabled when, what each control writes.
//
// A row binds to a choice (`key`, written with `settings.set`) or to a command
// (`command`, with `args`). `path` says where in the settings state (the
// `modules.settings` object the hub publishes) a value is read from. The
// page's tests walk this file and check every key, command and path against
// what the hub and the Rust module say they have (`fixtures/`).
//
// Strings are English, as the Swift's `L("...")`; `t()` finds the Russian.

import {t} from '../ui/strings.js';

// MARK: - Sections

export const SECTIONS = [
    {id: 'general', title: 'General', icon: 'general', subtitle: 'Where CapaTheNotch appears, and how it starts and updates.'},
    {id: 'providers', title: 'Providers', icon: 'providers', subtitle: 'Where Capacity comes from, and whether it is being read.'},
    {id: 'alerts', title: 'Alerts', icon: 'alerts', subtitle: 'A notification when a window is about to run out.'},
    {id: 'modules', title: 'Modules', icon: 'modules', subtitle: 'What the notch shows besides Capacity. Each one is off until you turn it on.'},
    {id: 'diagnostics', title: 'Diagnostics', icon: 'diagnostics', subtitle: 'What to send when something is wrong.'},
];

// `icon` is the `SettingsIcon` onboarding's `ModuleCard` draws; `symbol` the SF
// Symbol Settings' `ModuleHeader` draws (`BuiltInModule.symbol`).
export const MODULES = [
    {id: 'music', name: 'Music', icon: 'music', symbol: 'music.note', summary: "What's playing, with its controls, under Capacity."},
    {id: 'teleprompter', name: 'Teleprompter', icon: 'teleprompter', symbol: 'text.alignleft', summary: 'Your Script, scrolling beside the camera.'},
    {id: 'dictation', name: 'Dictation', icon: 'dictation', symbol: 'mic', summary: 'Speak, then keep typing.'},
    {id: 'shelf', name: 'Shelf', icon: 'shelf', symbol: 'tray', summary: 'Files at hand, dropped on the notch.'},
];

/** The switch each Module has, in the settings state. */
export const MODULE_SWITCH = {
    music: {key: 'musicEnabled', path: 'music.enabled'},
    teleprompter: {key: 'teleprompterEnabled', path: 'teleprompter.enabled'},
    dictation: {key: 'dictationEnabled', path: 'dictation.enabled'},
    shelf: {key: 'shelfEnabled', path: 'shelf.enabled'},
};

export const ONBOARDING_STEPS = [
    {id: 'welcome', name: 'Welcome', title: 'Welcome to CapaTheNotch', icon: 'notch',
        subtitle: 'How much of Codex, Claude Code and OpenCode is left, right under the notch — and a few tools beside it.'},
    {id: 'permissions', name: 'Permissions', title: 'Permissions', icon: 'permissions',
        subtitle: 'Everything macOS will ask about, at once, so nothing interrupts you later.'},
    {id: 'providers', name: 'Providers', title: 'Connect a Provider', icon: 'providers',
        subtitle: 'CapaTheNotch reads nothing until a Provider is on.'},
    {id: 'music', name: 'Music', title: 'Music', icon: 'music',
        subtitle: "Control what's playing without leaving what you're doing."},
    {id: 'teleprompter', name: 'Teleprompter', title: 'Teleprompter', icon: 'teleprompter',
        subtitle: 'Read your Script beside the camera, without looking away.'},
    {id: 'dictation', name: 'Dictation', title: 'Dictation', icon: 'dictation',
        subtitle: 'Speech becomes text on this Mac. The speech model is downloaded once.'},
];

/** Where a person is told, in the page's own header, what is wrong when the hub is not answering. */
export const NO_HUB = 'capa-daemon is not running. Start it, then reopen Settings.';

// MARK: - Values read from the state

export const get = (object, path) => path.split('.').reduce((o, k) => (o == null ? undefined : o[k]), object);

/** The settings state: what the Settings module publishes. */
export const settingsOf = state => state?.modules?.settings ?? null;

export const providerState = (s, id) => s.providers.find(p => p.provider === id);

// MARK: - Sentences with a little logic in them

/** "Every 5 minutes", "Every hour". */
export function refreshLabel(seconds) {
    return seconds < 3600 ? t('Every %d minutes', Math.round(seconds / 60)) : t('Every hour');
}

/** A Provider's status line in Settings: a colour and a sentence. */
export function providerStatus(on, view, now, {ago, clock}) {
    if (!on)
        return {tint: 'muted', line: t('Off')};
    switch (view?.state) {
    case 'fresh': return {tint: 'green', line: t('Fresh · read %@', ago(view.capturedAt, now))};
    case 'stale': return {tint: 'yellow', line: t('Stale · last read at %@', clock(view.capturedAt))};
    case 'disconnected': return {tint: 'red', line: t('Disconnected')};
    case 'mock': return {tint: 'muted', line: t('Mock')};
    default: return {tint: 'muted', line: t('Connecting')};
    }
}

/**
 * The reason a Provider is not being read, in its own words — or, while two
 * others are on, why this one cannot be turned on.
 */
export function providerNote(on, canConnect, view) {
    if (!on && !canConnect)
        return t('Turn one off to turn this on.');
    if (on && view && (view.state === 'stale' || view.state === 'disconnected') && view.guidance)
        return view.guidance;
    return null;
}

/** The consent asked before a Provider that reads something of yours is switched on (`AppDelegate`). */
export const CONSENT = {
    claudeCode: {
        title: 'Turn on Claude Code?',
        body: "CapaTheNotch asks Claude Code for its /usage — the report you see when you type /usage — and reads the Capacity in it, and the status line where Claude Code publishes one. It never reads Claude credentials, sessions, prompts or transcripts, and never talks to Anthropic itself.",
    },
    openCode: {
        title: 'Turn on OpenCode?',
        body: "CapaTheNotch reads your OpenCode Go key from OpenCode's own file and asks opencode.ai only for your plan's percentages and reset times — every five minutes, and when you refresh. The key is kept nowhere and sent nowhere else.",
    },
};

// MARK: - Permissions (`SystemAccess`)

/**
 * What the system is asked for, here. macOS asks for four; the others ask for
 * fewer, and say so in the same rows: notifications and the microphone, and
 * the way Dictation's text gets where the cursor is — Accessibility, as the
 * Swift names it. Insertion is no permission here: it works while a host that
 * can paste is connected (`insertionAllowed`), and there is nothing to ask for
 * while none is, so it stands `unavailable` (`SystemAccess.State`).
 */
export function accessRows(state, platform) {
    const dictation = state?.modules?.dictation ?? {};
    const state_ = (granted, known = true) => (!known ? 'notAsked' : granted ? 'granted' : 'notAsked');
    const insertion = !('insertionAllowed' in dictation) ? 'notAsked' : dictation.insertionAllowed ? 'granted' : 'unavailable';
    return [
        {id: 'notifications', icon: 'alerts', name: 'Notifications',
            reason: 'A Capacity Alert when a window is about to run out.', state: 'granted'},
        {id: 'microphone', icon: 'dictation', name: 'Microphone',
            reason: 'Dictation hears you only while you hold its shortcut.',
            state: platform === 'linux' ? (dictation.microphoneAllowed === false ? 'notAsked' : 'granted') : state_(dictation.microphoneAllowed, 'microphoneAllowed' in dictation),
            ask: {module: 'dictation', method: 'request_microphone'}},
        {id: 'insertion', icon: 'accessibility', name: 'Accessibility',
            reason: 'Dictation types its text where the cursor is.',
            state: insertion,
            ask: {module: 'dictation', method: 'request_insertion'}},
    ];
}

// MARK: - Everything a row can bind to, for the tests

/**
 * Walks a list of blocks and returns every `key` and `command` they write, and
 * every `path` they read, so the tests can compare them with the hub's.
 */
export function bindings(blocks) {
    const keys = new Set(), commands = new Set(), paths = new Set();
    const visit = node => {
        if (!node || typeof node !== 'object')
            return;
        if (Array.isArray(node))
            return node.forEach(visit);
        if (node.key)
            keys.add(node.key);
        if (node.keyPrefix)
            keys.add(`${node.keyPrefix}.`);
        if (node.command)
            commands.add(node.command);
        if (node.path)
            paths.add(node.path);
        for (const v of Object.values(node))
            if (v && typeof v === 'object')
                visit(v);
    };
    visit(blocks);
    return {keys: [...keys], commands: [...commands], paths: [...paths]};
}

// MARK: - The sections' blocks

/** The language choices, as the picker shows them: each names itself, System is translated. */
export const languageOptions = s => s.choices.language.map(c => ({id: c.id, title: c.id === 'system' ? t('System') : c.title}));
export const appearanceOptions = s => s.choices.appearance.map(c => ({id: c.id, title: t(c.title)}));
export const compactOptions = s => s.choices.compactWindow.map(c => ({id: c.id, title: t(c.title)}));
export const refreshOptions = s => s.choices.refresh.map(seconds => ({id: seconds, title: refreshLabel(seconds)}));
export const textSizeOptions = s => s.choices.textSize.map(c => ({id: c.id, title: t(c.title)}));
export const clippingLimitOptions = s => s.choices.clippingLimit.map(n => ({id: n, title: String(n)}));

/** The displays on offer: the built-in one first, then each the host knows. */
export const displayOptions = state => [
    {id: 0, title: t('Built-in display')},
    ...(state?.displays?.displays ?? []).map(d => ({id: d.id, title: d.name})),
];

/**
 * Whether this system can keep the surface out of screen sharing and
 * recordings: the Teleprompter says (`captureExclusion`), and where it has not
 * said, only Linux cannot.
 */
export function capturePossible(state, s) {
    const said = state?.modules?.teleprompter?.captureExclusion;
    return said ? said === 'supported' : s.platform !== 'linux';
}

export function generalBlocks(state, s) {
    const linux = !capturePossible(state, s);
    return [
        {kind: 'group',
            footnote: linux
                ? 'GNOME has no way to keep a window out of screen sharing or recordings, so CapaTheNotch always appears in them here, the Teleprompter included.'
                : 'macOS keeps CapaTheNotch out of the capture it controls. It cannot promise anything about a camera pointed at the screen.',
            rows: [
                {kind: 'picker', title: 'Language', key: 'language', path: 'language', options: languageOptions(s)},
                {kind: 'picker', title: 'Appearance', key: 'appearance', path: 'appearance', options: appearanceOptions(s)},
                {kind: 'toggle', title: 'Launch at login', key: 'launchAtLogin', path: 'launchAtLogin'},
                {kind: 'picker', title: 'Show on', key: 'displayId', path: 'displayId', options: displayOptions(state)},
                {kind: 'toggle', title: 'Appear in screen sharing and recordings', key: 'screenSharingAllowed',
                    path: 'screenSharingAllowed', disabled: linux},
                // Kapa is how the Modules already on look, not a Module, so it lives here (ADR 0006).
                {kind: 'toggle', title: 'Show Kapa', key: 'showsKapa', path: 'showsKapa'},
                // A file taken, dictation's outcome and a Capacity Alert; never while the Teleprompter runs (ADR 0007).
                {kind: 'toggle', title: 'Play sounds', key: 'playsSounds', path: 'playsSounds'},
            ]},
        {kind: 'group', footnote: 'Opens the latest release on GitHub. CapaTheNotch does not check on its own.', rows: [
            {kind: 'version', name: 'CapaTheNotch', path: 'version', button: {title: 'Check for Updates…', command: 'checkForUpdates'}},
        ]},
    ];
}

export function providersBlocks(state, s) {
    return [
        {kind: 'providers'},
        {kind: 'group', rows: [
            {kind: 'picker', title: 'Shown in the closed strip', key: 'compactWindow', path: 'compactWindow', options: compactOptions(s)},
            {kind: 'picker', title: 'While the surface is closed', key: 'backgroundRefreshSeconds',
                path: 'backgroundRefreshSeconds', options: refreshOptions(s)},
        ]},
    ];
}

export function alertsBlocks(state, s) {
    return [
        {kind: 'group', footnote: 'One warning per window, when it first drops below a tenth left, and nothing more until it recovers or resets.', rows: [
            {kind: 'toggle', title: 'Warn me when a window is about to run out', key: 'alertsEnabled', path: 'alertsEnabled'},
            {kind: 'divider'},
            ...s.providers.map(p => ({
                kind: 'toggle', title: p.name, literal: true, indent: 18, keyPrefix: 'alertsFor', provider: p.provider,
                path: `alertsFor.${p.provider}`, disabled: !s.alertsEnabled,
            })),
        ]},
    ];
}

export function diagnosticsBlocks(state, s) {
    return [
        {kind: 'group',
            footnote: 'Copied text carries versions, the states of Providers and Dictation, and timings. It carries no credential, address, identifier, Provider message or dictated text — those cannot reach it.',
            rows: [
                {kind: 'toggle', title: 'Keep a log for bug reports', key: 'keepsDiagnosticLog', path: 'keepsDiagnosticLog'},
                {kind: 'divider'},
                {kind: 'actions', height: 48, left: [
                    {title: 'Copy Diagnostics', action: 'copyDiagnostics'},
                    {title: 'Reveal Log', action: 'revealLog', disabled: !s.keepsDiagnosticLog},
                ], right: [{title: 'Run Onboarding Again', command: 'restartOnboarding'}]},
                {kind: 'report'},
            ]},
    ];
}

export const blocksFor = (section, state, s) => ({
    general: generalBlocks, providers: providersBlocks, alerts: alertsBlocks, diagnostics: diagnosticsBlocks,
})[section]?.(state, s) ?? [];

// MARK: - Modules

/** The Teleprompter card's rows, once it is on and expanded. */
export function teleprompterRows(state, s) {
    const tp = s.teleprompter;
    // The shortcuts the hub could not take (`unavailableShortcuts`): its `unavailable` list of
    // actions, or the older `shortcuts` [{action, unavailable}].
    const said = state?.modules?.teleprompter ?? {};
    const unavailable = Array.isArray(said.unavailable)
        ? said.unavailable.map(x => (typeof x === 'string' ? x : x?.action))
        : (said.shortcuts ?? []).filter(x => x.unavailable).map(x => x.action);
    return {
        script: {path: 'teleprompter.script', key: 'script',
            buttons: [
                {title: 'Paste from Clipboard', action: 'pasteScript'},
                {title: 'Restore Previous Script', command: 'restorePreviousScript', disabled: !tp.hasPreviousScript},
            ]},
        length: t('%d words · %d min', tp.wordCount, tp.minutes),
        speed: {title: 'Speed', path: 'teleprompter.multiplier', faster: {command: 'faster'}, slower: {command: 'slower'}},
        textSize: {title: 'Text size', key: 'teleprompterTextSize', path: 'teleprompter.textSize', options: textSizeOptions(s)},
        shortcuts: s.choices.teleprompterActions.map(a => ({
            id: a.id, title: a.title, target: `teleprompter.${a.id}`, path: `teleprompter.shortcuts.${a.id}`,
            unavailable: unavailable.includes(a.id),
        })),
    };
}

export const MUSIC_NOTE = 'Open, the surface has a page for it. It is read through a part of macOS that Apple does not publish, which a macOS update could close.';
export const SHELF_NOTE = 'Files dropped on the notch stay at hand until you drag them away or CapaTheNotch quits. Only a reference is kept; nothing is copied.';
export const SHELF_IMAGES = {
    title: 'Images and files from the clipboard',
    note: 'What you copy lands on the Shelf: a screenshot, a picture from a page, media or a document from a messenger. Copying in Finder, text and passwords are left alone. New screenshots saved to a folder land under Screenshots too.',
    key: 'shelfTakesClipboardImages', path: 'shelf.takesClipboardImages',
};
export const SHELF_TEXT = {
    title: 'Text from the clipboard',
    note: 'Text you copy is kept under Clipboard, newest first, to put on the clipboard again. Passwords and anything marked secret are left alone.',
    key: 'shelfKeepsText', path: 'shelf.keepsText',
};

/** The Dictation card's rows (`DictationCard`), by the state of the Module. */
export function dictationRows(state, s) {
    const d = state?.modules?.dictation ?? {};
    return {
        modelReady: !!d.modelReady,
        microphoneAllowed: d.microphoneAllowed !== false,
        insertionAllowed: !!d.insertionAllowed,
        /** No host that can paste: nothing to enable (`.unavailable`). */
        insertionUnavailable: d.insertionAllowed === false,
        shortcutUnavailable: !!d.shortcutUnavailable,
        savedResults: s.dictation.history.length,
    };
}

export const DICTATION_PAGES = {
    setup: {title: 'Set up Dictation', subtitle: 'Speak in Russian, with the IT terms you use every day.'},
    history: {title: 'Dictation history', subtitle: 'Your last 50 results, kept only on this Mac.'},
    replacements: {title: 'Word replacements', subtitle: 'Choose how recognised words are written.'},
};

// MARK: - What the Modules publish and accept, as they do
// Dictation (state.modules.dictation): modelReady, microphoneAllowed,
//   insertionAllowed, shortcutUnavailable, error (text | null),
//   download {fraction, label {kind: 'downloading' | 'checking', percent}} | null;
//   commands start_download, cancel_download, suspend_shortcut {suspend};
//   request_microphone, request_insertion and reveal_model, the rows' buttons.
// Teleprompter: state.modules.teleprompter.unavailable [action] (or shortcuts [{action, unavailable}]),
//   captureExclusion 'supported' | 'unsupported'; command suspendShortcuts {suspended}.
// Music: state.modules.music.unreadable (macOS only; absent elsewhere).
export const MODULE_CONTRACT = {
    dictation: {
        state: ['modelReady', 'microphoneAllowed', 'insertionAllowed', 'shortcutUnavailable', 'error', 'download'],
        commands: ['start_download', 'cancel_download', 'suspend_shortcut'],
        optionalCommands: ['request_microphone', 'request_insertion', 'reveal_model'],
    },
    teleprompter: {state: ['unavailable', 'captureExclusion'], commands: ['suspendShortcuts']},
    music: {state: [], commands: []},
};
