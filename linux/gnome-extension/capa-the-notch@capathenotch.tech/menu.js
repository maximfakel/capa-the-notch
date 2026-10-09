// The menu: what a menu bar item is for, and nothing else (`Bootstrap.swift`):
// Refresh Now, Settings…, Quit, under Kapa's silhouette in the top bar (the
// button is extension.js's). Said in the language chosen in
// Settings — from the start, before the daemon has said anything, as the
// Mac's menu reads the stored choice itself.

import GLib from 'gi://GLib';

import {setDictionary, t} from './ui/strings.js';

/** The menu's own words in Russian (`Localization.swift`), for before the first state. */
const MENU_RU = {
    'Refresh Now': 'Обновить сейчас',
    'Settings…': 'Настройки…',
    'Quit CapaTheNotch': 'Завершить CapaTheNotch',
};

/** The words, in the language of the state. */
export function useLanguage(state, extraRu = {}) {
    const dictionary = state?.dictionary ?? {};
    setDictionary(state?.language === 'ru' ? {...MENU_RU, ...dictionary, ...extraRu} : {});
}

/**
 * The language stored in the preferences (`language`: `system`, `english` or
 * `russian`), resolved as the hub resolves it: System is Russian when Russian
 * is the first language the system prefers. `en` when nothing can be read.
 */
export function storedLanguage() {
    let chosen = 'system';
    try {
        const path = GLib.build_filenamev([GLib.get_user_config_dir(), 'capa-the-notch', 'preferences.json']);
        const [ok, bytes] = GLib.file_get_contents(path);
        if (ok)
            chosen = JSON.parse(new TextDecoder().decode(bytes))?.language ?? 'system';
    } catch (_e) {
        // No file yet, or one that does not read: the system's language.
    }
    if (chosen === 'russian')
        return 'ru';
    if (chosen === 'english')
        return 'en';
    const first = GLib.get_language_names().find(name => name !== 'C' && name !== 'POSIX') ?? '';
    return first.startsWith('ru') ? 'ru' : 'en';
}

/** Until the first state: the menu in the stored language. */
export function useStoredLanguage(extraRu = {}) {
    setDictionary(storedLanguage() === 'ru' ? {...MENU_RU, ...extraRu} : {});
}

/**
 * Each item's shortcut while the menu is open (`.keyboardShortcut` in
 * Bootstrap.swift): ⌘R, ⌘, and ⌘Q, which are Ctrl here. `key` is the
 * character typed; `keycode` the key itself (evdev + 8), for a layout that
 * types no Latin letters (Russian), as GTK matches accelerators.
 */
export const ENTRIES = [
    {id: 'refresh', title: 'Refresh Now', key: 'r', keycode: 27, accel: 'Ctrl+R'},
    {id: 'settings', title: 'Settings…', key: ',', keycode: 59, accel: 'Ctrl+,'},
    {id: 'quit', title: 'Quit CapaTheNotch', key: 'q', keycode: 24, accel: 'Ctrl+Q'},
];

/**
 * The item a Ctrl+key asks for, or null. `symbol` is the key symbol typed
 * (Latin-1 symbols are their characters), `keycode` the hardware key.
 */
export function shortcutFor(symbol, keycode) {
    if (symbol > 0 && symbol < 0x100) {
        const typed = String.fromCharCode(symbol).toLowerCase();
        return ENTRIES.find(entry => entry.key === typed)?.id ?? null;
    }
    return ENTRIES.find(entry => entry.keycode === keycode)?.id ?? null;
}

/** Fills a popup menu with the three items. `act(id)` does what one asks. */
export function fillMenu(menu, act) {
    menu.removeAll?.();
    const make = entry => {
        const item = menu.addAction(t(entry.title), () => act(entry.id));
        // Dim, at the right, as a GNOME menu shows an accelerator.
        if (AccelLabel)
            item.add_child(AccelLabel(entry.accel));
        return item;
    };
    make(ENTRIES[0]);
    menu.addMenuItem(new Separator());
    make(ENTRIES[1]);
    menu.addMenuItem(new Separator());
    make(ENTRIES[2]);
}

// A separator from the shell's own popup menu module, found once.
let Separator = null;
export function setSeparator(cls) {
    Separator = cls;
}

// What draws an item's accelerator, given by the extension: St is the Shell's
// alone, and this file is read by the settings window's program too.
let AccelLabel = null;
export function setAccelLabel(make) {
    AccelLabel = make;
}
