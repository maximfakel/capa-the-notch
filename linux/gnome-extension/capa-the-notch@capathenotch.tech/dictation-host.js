// What only the compositor's own process can do for Dictation: grab the
// shortcut and tell hold from release, see which window is in front, put text
// on the clipboard and press Ctrl+V into the window that was. The hub asks by
// `ModuleEvent`s and is answered by commands (linux/crates/dictation/src/bridge.rs
// has the whole conversation).
//
//   register  {shortcut, accelerator, evdev, escape}  grab the keys, or let them go
//   copy      {text}                                  the clipboard, as our own
//   insert    {token, text, target}                   verify, paste, answer `inserted`
//   end_hold  {}                                      the session is over (the system
//                                                     is going to sleep): stop listening
//                                                     for the key's release
//
// Hold and release: the accelerator is grabbed with `Meta.Display.grab_accelerator`
// and fires on the press; while the key is held a modal grab hears its release
// (a Wayland client cannot see keys that are not its own, but the shell can),
// and only without a grab is the chord's modifiers' release watched instead.
// Escape is grabbed as an accelerator only while a session needs it, as the
// Swift app registers it, so no other use of Escape is touched.

import Clutter from 'gi://Clutter';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import St from 'gi://St';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';

import {writeOwnText} from './shelf-host.js';

/** A recording is cut off at sixty seconds; a stuck grab is let go a little after. */
const GRAB_LIMIT_S = 65;

const TARGET_NOT_ACTIVE = 'The target application stopped being active before insertion.';
const PASTE_FAILED = 'The text could not be pasted. It is still in the clipboard.';

/** The paste's keys, as linux/input-event-codes.h numbers them. */
const EVDEV_LEFTCTRL = 29;
const EVDEV_LEFTSHIFT = 42;
const EVDEV_V = 47;

/** Terminals paste with Ctrl+Shift+V. */
const TERMINALS = new Set([
    'gnome-terminal-server', 'org.gnome.terminal', 'org.gnome.console', 'kgx', 'org.gnome.ptyxis', 'ptyxis',
    'konsole', 'alacritty', 'kitty', 'foot', 'wezterm', 'org.wezfurlong.wezterm', 'xterm', 'tilix', 'terminator',
    'xfce4-terminal', 'st', 'urxvt',
]);

/** CapaTheNotch's own applications (Settings, …): never a place to insert into. */
const OWN_APP_PREFIX = 'tech.capathenotch.';

/**
 * The chord's modifiers, one entry each: the bits any of which say that
 * modifier is down. Super is two: `global.get_pointer()` reports the Super
 * key as MOD4, and other paths as SUPER. Empty when the chord has none.
 */
export function chordMasks(accelerator, ModifierType = Clutter.ModifierType) {
    const text = accelerator ?? '';
    const masks = [];
    if (text.includes('<Control>')) masks.push(ModifierType.CONTROL_MASK);
    if (text.includes('<Alt>')) masks.push(ModifierType.MOD1_MASK);
    if (text.includes('<Shift>')) masks.push(ModifierType.SHIFT_MASK);
    if (text.includes('<Super>')) masks.push(ModifierType.SUPER_MASK | ModifierType.MOD4_MASK);
    return masks;
}

/** Whether every modifier of the chord is held in the pointer's `state`. */
export function chordHeld(state, masks) {
    return masks.every(mask => (state & mask) !== 0);
}

/**
 * Whether the window is one of CapaTheNotch's own — the Swift excludes its
 * own bundle as a target (`DictationDelivery.capture`). Told by the
 * application the shell matched it to, and by its GTK application id and
 * WM_CLASS, which `tech.capathenotch.Settings` sets.
 */
function isOwnWindow(window) {
    const ids = [
        Shell.WindowTracker.get_default().get_window_app(window)?.get_id?.(),
        window.get_gtk_application_id?.(),
        window.get_sandboxed_app_id?.(),
        window.get_wm_class?.(),
        window.get_wm_class_instance?.(),
    ];
    return ids.some(id => typeof id === 'string' && id.toLowerCase().startsWith(OWN_APP_PREFIX));
}

export class DictationHost {
    /** @param {(method: string, args?: object) => Promise<any>} call the hub's `call('dictation', …)` */
    constructor(call) {
        this._call = (method, args) => call('dictation', method, args).catch(e => console.error(`capa-the-notch: dictation ${method}: ${e}`));
        this._action = 0;
        this._escapeAction = 0;
        this._accelerator = null;
        this._grab = null;
        this._grabActor = null;
        this._watch = 0;
        this._seatDevice = null;
        this._activated = global.display.connect('accelerator-activated', (_d, action) => this._activate(action));
        // Which window last had a password field in focus, as accessibility tells it;
        // listened for only while there is a shortcut.
    }

    /** A host that has just connected says what it can do. */
    ready() {
        this._call('host_ready', {insert: true});
    }

    /** The hub's state changed: grab, or let go of, what it asks for. */
    update(state) {
        const registration = state?.registration;
        if (!registration)
            return;
        this._register(registration.shortcut ? registration.accelerator : null, registration.evdev);
        this._grabEscape(registration.escape);
    }

    onEvent(name, data) {
        switch (name) {
        case 'copy': this._copy(data.text); break;
        case 'insert': this._insert(data); break;
        case 'register': this._register(data.shortcut ? data.accelerator ?? this._accelerator : null, data.evdev ?? null); this._grabEscape(data.escape); break;
        case 'end_hold': this._endHold(false); break;
        default: break;
        }
    }

    // MARK: - The keys

    _register(accelerator, evdev) {
        if (evdev != null)
            this._evdev = evdev;
        if (accelerator === this._accelerator)
            return;
        if (this._action) {
            global.display.ungrab_accelerator(this._action);
            Main.wm.allowKeybinding(Meta.external_binding_name_for_action(this._action), Shell.ActionMode.NONE);
            this._action = 0;
        }
        this._accelerator = accelerator;
        if (!accelerator)
            return;
        const action = global.display.grab_accelerator(accelerator, Meta.KeyBindingFlags.NONE);
        if (action === Meta.KeyBindingAction.NONE) {
            // The key is taken: the hub is told, and the person is told by Settings.
            this._call('shortcut_registered', {ok: false});
            return;
        }
        this._action = action;
        Main.wm.allowKeybinding(Meta.external_binding_name_for_action(action), Shell.ActionMode.ALL);
        this._call('shortcut_registered', {ok: true});
    }

    _grabEscape(on) {
        if (on && !this._escapeAction) {
            const action = global.display.grab_accelerator('Escape', Meta.KeyBindingFlags.NONE);
            if (action !== Meta.KeyBindingAction.NONE) {
                this._escapeAction = action;
                Main.wm.allowKeybinding(Meta.external_binding_name_for_action(action), Shell.ActionMode.ALL);
            }
        } else if (!on && this._escapeAction) {
            global.display.ungrab_accelerator(this._escapeAction);
            Main.wm.allowKeybinding(Meta.external_binding_name_for_action(this._escapeAction), Shell.ActionMode.NONE);
            this._escapeAction = 0;
        }
    }

    _activate(action) {
        if (action === this._escapeAction && action) {
            this._call('escape_pressed');
            return;
        }
        if (action !== this._action || !action)
            return;
        this._call('hotkey_pressed', {target: this._target()});
        this._holdUntilReleased();
    }

    /** What is in front: the window, by its id. */
    _target() {
        const window = global.display.focus_window;
        if (!window)
            return null;
        const id = String(window.get_id());
        return {
            app: window.get_wm_class() ?? '',
            window: id,
            // A password field cannot be told from here. Accessibility could say, but only as a
            // client of it inside the compositor, whose synchronous calls back into the shell's own
            // objects stall the whole session (it froze when the surface took the keyboard): the
            // Shell must never be an AT-SPI client of itself.
            secure: false,
            own: isOwnWindow(window),
        };
    }

    /**
     * The shortcut went down. The recording ends when the KEY is let go, as
     * the Swift's hot key reports its release: a modal grab hears that
     * release, since it sees every key while it is held. Only a shell that
     * refuses the grab is watched by the chord's modifiers instead, which
     * ends the recording when the chord is let go.
     */
    _holdUntilReleased() {
        this._endHold(false);
        const actor = new St.Widget({reactive: true, can_focus: true});
        Main.uiGroup.add_child(actor);
        const grab = Main.pushModal(actor, {actionMode: Shell.ActionMode.NONE});
        const finish = () => this._endHold(true);
        if (grab) {
            this._grab = grab;
            this._grabActor = actor;
            actor.connect('key-release-event', (_a, event) => {
                // X keycodes are evdev codes plus eight. A modifier let go first does not end it.
                if (this._evdev == null || event.get_key_code() === this._evdev + 8)
                    finish();
                return Clutter.EVENT_STOP;
            });
            actor.connect('key-press-event', (_a, event) => {
                if (event.get_key_symbol() === Clutter.KEY_Escape) {
                    this._endHold(false);
                    this._call('escape_pressed');
                }
                return Clutter.EVENT_STOP;
            });
            actor.grab_key_focus();
            // A quick tap can be let go before the grab is in place, and then
            // the grab never hears a release. The key itself cannot be read,
            // but the chord's modifiers can: if they are already up, the
            // shortcut was let go, so this is the release.
            const chord = chordMasks(this._accelerator);
            if (chord.length && !chordHeld(global.get_pointer()[2], chord)) {
                finish();
                return;
            }
        } else {
            actor.destroy();
            // No grab, so the key's own release cannot be heard: the chord's
            // modifiers are watched every 30 ms, and their release ends it.
            const chord = chordMasks(this._accelerator);
            if (chord.length) {
                // The modifiers go down a moment after the accelerator fires on some keymaps: wait for them first.
                let seen = false;
                this._watch = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 30, () => {
                    const held = chordHeld(global.get_pointer()[2], chord);
                    seen ||= held;
                    if (held || !seen)
                        return GLib.SOURCE_CONTINUE;
                    this._watch = 0;
                    finish();
                    return GLib.SOURCE_REMOVE;
                });
            }
        }
        // A grab never outlives a recording.
        this._limit = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, GRAB_LIMIT_S, () => {
            this._limit = 0;
            this._endHold(true);
            return GLib.SOURCE_REMOVE;
        });
    }

    _endHold(released) {
        if (this._watch) {
            GLib.source_remove(this._watch);
            this._watch = 0;
        }
        if (this._limit) {
            GLib.source_remove(this._limit);
            this._limit = 0;
        }
        if (this._grab) {
            Main.popModal(this._grab);
            this._grab = null;
        }
        this._grabActor?.destroy();
        this._grabActor = null;
        if (released)
            this._call('hotkey_released');
    }

    // MARK: - The clipboard and the paste

    /** As the Swift's `OwnClipboard.copy`: the Shelf does not keep it as a Clipping. */
    _copy(text) {
        writeOwnText(text);
    }

    /**
     * Verifies the window is still the one, pastes into it, and tells the hub
     * how it went: inserted once the paste is pressed, as the Swift reports it
     * once its paste is posted (`DictationDelivery.insert`).
     */
    _insert({token, text, target}) {
        const window = global.display.focus_window;
        if (!window || String(window.get_id()) !== target.window) {
            this._call('inserted', {token, message: TARGET_NOT_ACTIVE});
            return;
        }
        // The text is already on the clipboard (`copy` came first); press the paste.
        try {
            this._pressPaste(TERMINALS.has((window.get_wm_class() ?? '').toLowerCase()));
        } catch (e) {
            console.error(`capa-the-notch: could not press the paste: ${e}`);
            this._call('inserted', {token, message: PASTE_FAILED});
            return;
        }
        this._call('inserted', {token, message: null});
    }

    _pressPaste(shift) {
        if (!this._seatDevice) {
            // GNOME 51 has no `Clutter.get_default_backend()`: the stage's context holds the backend.
            const backend = global.stage?.context?.get_backend?.() ?? Clutter.get_default_backend();
            const seat = backend.get_default_seat();
            this._seatDevice = seat.create_virtual_device(Clutter.InputDeviceType.KEYBOARD_DEVICE);
        }
        // The keys themselves, by their evdev codes, as the Swift posts virtual
        // key 9 (V) rather than a character: under a layout with no Latin "v"
        // (Russian) a keyval has no key to press and the paste is lost, while
        // applications take Ctrl and the V key as paste in any layout.
        const dev = this._seatDevice;
        const press = (key, state) => dev.notify_key(GLib.get_monotonic_time(), key, state);
        const {PRESSED, RELEASED} = Clutter.KeyState;
        press(EVDEV_LEFTCTRL, PRESSED);
        if (shift)
            press(EVDEV_LEFTSHIFT, PRESSED);
        press(EVDEV_V, PRESSED);
        press(EVDEV_V, RELEASED);
        if (shift)
            press(EVDEV_LEFTSHIFT, RELEASED);
        press(EVDEV_LEFTCTRL, RELEASED);
    }

    destroy() {
        this._endHold(false);
        this._register(null, null);
        this._grabEscape(false);
        if (this._activated)
            global.display.disconnect(this._activated);
        this._activated = 0;
        this._seatDevice = null;
    }
}
