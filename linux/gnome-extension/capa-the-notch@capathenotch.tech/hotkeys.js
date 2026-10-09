// The Teleprompter's global shortcuts, bound by the shell. An application
// cannot grab a key on Wayland, so the hub only says which keys it wants (the
// Module's state, `hotKeys`) and this binds them with `Main.wm.addKeybinding`;
// a press goes back to the hub as the command `hotKey`. Bound only while the
// Module is on: an empty list unbinds everything.
//
// A key the shell already gives to something else — the standard ⌃⌥↑/↓ are
// GNOME's workspace keys, ⌃⌥Esc its cycle-panels — is not bound: the shell's
// own binding would win and ours would never fire. Those, and any the shell
// refuses, go back to the hub as `keysUnavailable {actions}`, which Settings
// shows as Carbon's refusals are shown on the Mac (`unavailableShortcuts`).

import Gio from 'gi://Gio';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';

const KEY = {
    startOrPause: 'teleprompter-start-or-pause',
    stop: 'teleprompter-stop',
    faster: 'teleprompter-faster',
    slower: 'teleprompter-slower',
};

/** Where GNOME keeps the keys it binds itself. */
const SYSTEM_SCHEMAS = [
    'org.gnome.desktop.wm.keybindings',
    'org.gnome.shell.keybindings',
    'org.gnome.mutter.keybindings',
    'org.gnome.mutter.wayland.keybindings',
    'org.gnome.settings-daemon.plugins.media-keys',
];
const CUSTOM_SCHEMA = 'org.gnome.settings-daemon.plugins.media-keys.custom-keybinding';

const MODIFIER_NAMES = {
    control: 'control', ctrl: 'control', ctl: 'control', primary: 'control',
    alt: 'alt', mod1: 'alt',
    super: 'super', mod4: 'super',
    shift: 'shift', meta: 'meta', hyper: 'hyper',
};

/**
 * An accelerator in one spelling: `<Primary><Alt>Up`, `<Ctrl><Alt>up` and
 * `<Alt><Control>Up` are the same keys. Null for none (`''`, `disabled`).
 */
export function normalizeAccelerator(accelerator) {
    if (typeof accelerator !== 'string')
        return null;
    let rest = accelerator.trim();
    const modifiers = new Set();
    let match;
    while ((match = /^<([^>]+)>/.exec(rest))) {
        const name = match[1].toLowerCase();
        modifiers.add(MODIFIER_NAMES[name] ?? name);
        rest = rest.slice(match[0].length);
    }
    const key = rest.trim().toLowerCase();
    if (!key || key === 'disabled')
        return null;
    return `${[...modifiers].sort().map(m => `<${m}>`).join('')}${key}`;
}

/** Every accelerator one `Gio.Settings` holds, whether a key is a list (`as`) or one (`s`). */
function acceleratorsOf(settings, schema) {
    const out = [];
    for (const name of schema.list_keys()) {
        const type = schema.get_key(name).get_value_type().dup_string();
        if (type !== 'as' && type !== 's')
            continue;
        const value = settings.get_value(name).deep_unpack();
        for (const accelerator of Array.isArray(value) ? value : [value]) {
            const normal = normalizeAccelerator(accelerator);
            if (normal)
                out.push(normal);
        }
    }
    return out;
}

/** The keys GNOME already gives to something: its window manager's, the shell's, the media keys and custom shortcuts. */
function systemAccelerators() {
    const taken = new Set();
    const source = Gio.SettingsSchemaSource.get_default();
    if (!source)
        return taken;
    const read = (id, path = null) => {
        const schema = source.lookup(id, true);
        if (!schema)
            return null;
        try {
            const settings = path ? new Gio.Settings({settings_schema: schema, path}) : new Gio.Settings({settings_schema: schema});
            for (const accelerator of acceleratorsOf(settings, schema))
                taken.add(accelerator);
            return settings;
        } catch (e) {
            console.debug(`capa-the-notch: reading ${id}: ${e}`);
            return null;
        }
    };
    for (const id of SYSTEM_SCHEMAS) {
        const settings = read(id);
        // The custom shortcuts a person made in Settings, each at a path of its own.
        if (settings && id === 'org.gnome.settings-daemon.plugins.media-keys' &&
            settings.settings_schema.has_key('custom-keybindings')) {
            for (const path of settings.get_strv('custom-keybindings')) {
                const custom = source.lookup(CUSTOM_SCHEMA, true);
                if (!custom)
                    break;
                try {
                    const one = new Gio.Settings({settings_schema: custom, path});
                    const normal = normalizeAccelerator(one.get_string('binding'));
                    if (normal)
                        taken.add(normal);
                } catch (e) {
                    console.debug(`capa-the-notch: reading ${path}: ${e}`);
                }
            }
        }
    }
    return taken;
}

export class ShellKeys {
    /**
     * @param {Gio.Settings} settings the extension's, with the schema's four keys
     * @param {(action: string) => void} press called with the action when its key is pressed
     * @param {(actions: string[]) => void} [report] called with the actions whose keys could not be had,
     *        to send as the hub's `teleprompter.keysUnavailable {actions}`
     */
    constructor(settings, press, report = null) {
        this._settings = settings;
        this._press = press;
        this._report = report;
        this._bound = new Map(); // key name -> {action, accelerator, ok}
        this._sent = null; // the unavailable actions last reported and not yet seen in the hub's state
    }

    /** @param {{action: string, accelerator: string, unavailable?: boolean}[]} wanted */
    update(wanted) {
        const next = new Map();
        for (const {action, accelerator} of wanted ?? []) {
            if (KEY[action])
                next.set(KEY[action], {action, accelerator});
        }
        for (const [name, bound] of [...this._bound]) {
            if (next.get(name)?.accelerator === bound.accelerator)
                continue;
            if (bound.ok)
                Main.wm.removeKeybinding(name);
            this._settings.set_strv(name, []);
            this._bound.delete(name);
        }
        let taken = null;
        for (const [name, {action, accelerator}] of next) {
            if (this._bound.has(name))
                continue;
            taken ??= systemAccelerators();
            this._bound.set(name, {action, accelerator, ok: this._bind(name, action, accelerator, taken)});
        }
        this._tell(wanted ?? []);
    }

    /** Binds one key, unless the shell already gives it to something; false when it is not ours. */
    _bind(name, action, accelerator, taken) {
        if (taken.has(normalizeAccelerator(accelerator)))
            return false;
        this._settings.set_strv(name, [accelerator]);
        // Held down, a key works once (Carbon's hot keys do not repeat); and
        // not on the lock screen or the login screen.
        const id = Main.wm.addKeybinding(name, this._settings, Meta.KeyBindingFlags.IGNORE_AUTOREPEAT,
            Shell.ActionMode.NORMAL | Shell.ActionMode.OVERVIEW | Shell.ActionMode.POPUP,
            () => this._press(action));
        if (id === Meta.KeyBindingAction.NONE) {
            // Refused: whatever the shell kept of it goes.
            Main.wm.removeKeybinding(name);
            this._settings.set_strv(name, []);
            return false;
        }
        return true;
    }

    /** Tells the hub which keys could not be had, when that is not what its state already says. */
    _tell(wanted) {
        const mine = [...this._bound.values()].filter(b => !b.ok).map(b => b.action).sort();
        const theirs = wanted.filter(w => w.unavailable && KEY[w.action]).map(w => w.action).sort();
        const key = mine.join(',');
        if (key === theirs.join(',')) {
            this._sent = null;
            return;
        }
        if (key === this._sent || !this._report)
            return;
        this._sent = key;
        this._report(mine);
    }

    destroy() {
        this.update([]);
    }
}
