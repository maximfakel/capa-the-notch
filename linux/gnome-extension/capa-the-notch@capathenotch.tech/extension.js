import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GioUnix from 'gi://GioUnix';
import St from 'gi://St';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';

import {DictationHost} from './dictation-host.js';
import {fillMenu, setAccelLabel, setSeparator, shortcutFor, useLanguage, useStoredLanguage} from './menu.js';
import {EXTRA_RU} from './settings/strings-extra.js';
import {settingsQuery} from './settings/target.js';
import {DaemonClient} from './daemon.js';
import {ShelfHost} from './shelf-host.js';
import {DndHost} from './dnd-host.js';
import {ShellKeys} from './hotkeys.js';
import {PlatformGlue, launchesAtLogin} from './platform.js';
import {Surface} from './surface.js';

setSeparator(PopupMenu.PopupSeparatorMenuItem);
setAccelLabel(text => new St.Label({
    text, x_expand: true, x_align: Clutter.ActorAlign.END, y_align: Clutter.ActorAlign.CENTER, opacity: 140,
}));

// The settings window's program (settings-app.js): a GApplication, whose
// actions are on the bus under its own name.
const SETTINGS_NAME = 'tech.capathenotch.Settings';
const SETTINGS_PATH = '/tech/capathenotch/Settings';

// Launching CapaTheNotch, as opening CapaTheNotch.app does: the application
// entry and the autostart entry call `Show` (linux/packaging).
const SHELL_NAME = 'tech.capathenotch.Shell';
const SHELL_PATH = '/tech/capathenotch/Shell';
const SHELL_INTERFACE = `
<node>
  <interface name="tech.capathenotch.Shell">
    <method name="Show"/>
    <method name="Open"/>
  </interface>
</node>`;

// Whether CapaTheNotch is not running in this Shell session: quit from its
// menu, or — at login — left alone because it does not launch at login. Kept
// in memory, for this session only: across a screen lock the extension is
// enabled again and stays as it was; the next login starts afresh. `null`
// until the first enable has decided.
let dormant = null;

export default class CapaTheNotch extends Extension {
    enable() {
        this._exportShell();
        // At login the Shell enables every extension; CapaTheNotch appears
        // only if the person has it launch at login (`LaunchAtLogin`). Enabled
        // any other way — installed, switched on — it starts.
        dormant ??= Main.layoutManager._startingUp && !launchesAtLogin();
        if (!dormant)
            this._start();
    }

    _start() {
        if (this._running)
            return;
        try {
            this._enable();
            this._running = true;
        } catch (e) {
            // Half an extension is worse than none: put the bar back as it was.
            console.error(`capa-the-notch: could not start: ${e}\n${e.stack}`);
            this._stop();
            throw e;
        }
    }

    /**
     * `Show` (at login) and `Open` (the application entry): CapaTheNotch comes
     * back after a Quit. Opened while it runs, its Settings open, so a launch
     * from the applications is never without an answer — the Mac app, a menu
     * bar item, shows nothing then, but an application here is expected to
     * open a window. Login only starts it, so it never opens Settings by itself.
     */
    _show({open = false} = {}) {
        if (this._surface && !dormant) {
            if (open)
                this._openSettings();
            return;
        }
        dormant = false;
        try {
            this._start();
        } catch (_e) {
            // Said in the log by `_start`.
        }
    }

    _exportShell() {
        if (this._shellObject)
            return;
        this._shellObject = Gio.DBusExportedObject.wrapJSObject(SHELL_INTERFACE, {
            // Not from inside the D-Bus call.
            Show: () => GLib.idle_add(GLib.PRIORITY_DEFAULT, () => {
                if (this._shellObject)
                    this._show();
                return GLib.SOURCE_REMOVE;
            }),
            Open: () => GLib.idle_add(GLib.PRIORITY_DEFAULT, () => {
                if (this._shellObject)
                    this._show({open: true});
                return GLib.SOURCE_REMOVE;
            }),
        });
        this._shellObject.export(Gio.DBus.session, SHELL_PATH);
        this._shellName = Gio.bus_own_name_on_connection(Gio.DBus.session, SHELL_NAME,
            Gio.BusNameOwnerFlags.NONE, null, null);
    }

    _unexportShell() {
        if (this._shellName)
            Gio.bus_unown_name(this._shellName);
        this._shellName = 0;
        this._shellObject?.unexport();
        this._shellObject = null;
    }

    _enable() {
        this._state = null;
        // The menu in the chosen language before the daemon has said anything.
        useStoredLanguage(EXTRA_RU);

        this._surface = new Surface({
            barHeight: () => Math.max(Math.round(Main.panel.height), 28),
            setExpanded: expanded => this._client.setExpanded(expanded),
            // A card's refresh names its Provider; Refresh Now reads them all.
            refresh: provider => provider
                ? this._client.call('hub', 'refresh', {provider}).catch(e => console.error(`capa-the-notch: ${e}`))
                : this._client.refresh(),
            // A Provider that is not read yet is connected in Settings, where what is read is said first.
            connect: () => this._openSettings('providers'),
            openSettings: asked => this._openSettings(asked),
            playSound: cue => this._client?.playSound(cue),
            call: (module, method, args) => this._client.call(module, method, args),
            // Read at the click, and only then.
            readClipboard: () => new Promise(resolve => {
                St.Clipboard.get_default().get_text(St.ClipboardType.CLIPBOARD, (_c, text) => resolve(text ?? ''));
            }),
            // The surface covers the desktop's clock: the time it shows opens the calendar instead.
            openCalendar: () => this._openCalendar(),
            writeClipboard: text => this._shelf?.writeText(text),
            startFileDrag: path => this._shelf?.writeFile(path),
        });
        this._keys = new ShellKeys(this.getSettings(),
            action => this._client?.call('teleprompter', 'hotKey', {action}).catch(e => console.error(`capa-the-notch: ${e}`)),
            actions => this._client?.call('teleprompter', 'keysUnavailable', {actions}).catch(e => console.error(`capa-the-notch: ${e}`)));
        this._client = new DaemonClient({
            onState: state => {
                this._state = state;
                this._surface.setState(state);
                useLanguage(state, EXTRA_RU);
                this._fillMenu(state.language);
                this._firstRun(state);
                // The Teleprompter's keys are bound while the Module is on, and only then.
                this._keys?.update(state.modules?.teleprompter?.hotKeys ?? []);
                this._glue?.state(state);
                // The drop window is kept while the Shelf is on, and only then.
                this._dnd?.keep(!!state.modules?.shelf?.view?.enabled);
                // Dictation's shortcut is grabbed while the Module is on, and only then.
                this._dictation?.update(state.modules?.dictation);
            },
            onAlert: alert => this._alert(alert),
            onModuleEvent: (module, name, data) => {
                if (module === 'settings' && name === 'openOnboarding')
                    this._openSettings(null, {onboarding: true});
                // Onboarding finished: the surface opens, pinned, on what was chosen.
                if (module === 'settings' && name === 'onboardingFinished')
                    this._surface.openPinned();
                // A Provider not connected, refreshed from its card: its consent is asked in Settings ▸ Providers.
                if (module === 'hub' && name === 'openSettings')
                    this._openSettings(data?.section ?? null);
                if (module === 'dictation')
                    this._dictation?.onEvent(name, data);
                this._surface.moduleEvent(module, name, data);
            },
            onRunning: running => {
                this._surface.setRunning(running);
                if (running) {
                    this._glue?.report();
                    this._dictation?.ready();
                }
            },
        });

        // The shortcut, the window in front and the paste: what only the compositor can do for Dictation.
        this._dictation = new DictationHost((module, method, args) => this._client.call(module, method, args));

        // The clipboard, for the Shelf: what only the Shell can see on Wayland.
        this._shelf = new ShelfHost({
            shelfState: () => this._state?.modules?.shelf ?? null,
            push: args => this._client.call('shelf', 'clipboard', args),
            notify: (title, body) => Main.notify(title, body),
        });

        // Files carried over from other programs: a window under the surface takes them (dnd-host.js).
        this._dnd = new DndHost({
            surface: this._surface,
            shelfOn: () => !!this._state?.modules?.shelf?.view?.enabled,
            monitor: () => this._glue?.monitor() ?? Main.layoutManager.primaryMonitor,
        });

        // Monitors, fullscreen and alerts: what only the shell knows (platform.js).
        this._glue = new PlatformGlue({client: this._client, surface: this._surface, place: () => this._place()});

        // Over a fullscreen application the surface stays, as it does on macOS.
        Main.layoutManager.addTopChrome(this._surface.actor);
        // Under what is being dragged, though: the icon of a file carried over
        // the surface stays in sight, as macOS draws a drag image above all.
        const feedback = global.compositor.get_feedback_group();
        if (feedback.get_parent() === Main.layoutManager.uiGroup)
            Main.layoutManager.uiGroup.set_child_below_sibling(this._surface.actor, feedback);
        this._addButton();
        this._watchCalendar();
        // The banners come in at the right: the middle of the bar is the surface's.
        this._bannerAlign = Main.messageTray._bannerBin.x_align;
        Main.messageTray._bannerBin.x_align = Clutter.ActorAlign.END;
        this._place();
        this._monitors = Main.layoutManager.connect('monitors-changed', () => this._place());
        // Enabled at login, before the monitors are known: place again once they are.
        if (Main.layoutManager._startingUp)
            this._startup = Main.layoutManager.connect('startup-complete', () => this._place());

        // A click anywhere else, or Escape, lets a pinned surface go.
        this._stage = [
            global.stage.connect('button-press-event', (_s, event) => {
                // A press with no actor under it (a window's own surface) is outside too.
                const source = event.get_source();
                if (this._surface.pinned && (!source || !this._surface.actor.contains(source)))
                    this._surface.dismiss();
                return Clutter.EVENT_PROPAGATE;
            }),
            global.stage.connect('key-press-event', (_s, event) => {
                if (this._surface.pinned && event.get_key_symbol() === Clutter.KEY_Escape) {
                    this._surface.dismiss();
                    return Clutter.EVENT_STOP;
                }
                return Clutter.EVENT_PROPAGATE;
            }),
        ];
    }

    disable() {
        this._stop();
        this._unexportShell();
    }

    /** Takes everything down but the `Show` object: what Quit and `disable` share. */
    _stop() {
        this._running = false;
        for (const id of this._stage ?? [])
            global.stage.disconnect(id);
        this._stage = null;
        if (this._monitors)
            Main.layoutManager.disconnect(this._monitors);
        this._monitors = 0;
        if (this._startup)
            Main.layoutManager.disconnect(this._startup);
        this._startup = 0;
        this._unwatchCalendar();
        this._button?.destroy();
        this._button = null;
        this._menuLanguage = null;
        this._welcomed = false;
        this._keys?.destroy();
        this._keys = null;
        this._dictation?.destroy();
        this._dictation = null;
        this._glue?.destroy();
        this._glue = null;
        if (this._bannerAlign !== undefined) {
            Main.messageTray._bannerBin.x_align = this._bannerAlign;
            this._bannerAlign = undefined;
        }
        this._dnd?.destroy();
        this._dnd = null;
        this._shelf?.destroy();
        this._shelf = null;
        this._client?.destroy();
        this._client = null;
        if (this._surface) {
            // Not yet added to the chrome when `enable` failed before that.
            if (this._surface.actor.get_parent())
                Main.layoutManager.removeChrome(this._surface.actor);
            this._surface.destroy();
        }
        this._surface = null;
        this._state = null;
    }

    /** Settings and onboarding are a window of their own: a GTK program holding the shared page. */
    _openSettings(asked = null, {onboarding = false} = {}) {
        // Where the asker means: 'modules' is the Teleprompter's Edit Script, 'dictation' its own button.
        const query = onboarding ? 'onboarding=1' : settingsQuery(asked);
        try {
            const entry = GioUnix.DesktopAppInfo.new('tech.capathenotch.Settings.desktop');
            if (!entry)
                throw new Error('the desktop entry tech.capathenotch.Settings is not installed');
            entry.launch_uris([`capa-settings:?${query}`], global.create_app_launch_context(0, -1));
        } catch (e) {
            console.error(`capa-the-notch: could not open Settings: ${e}`);
        }
    }

    /** What the menu's three items do. */
    _act(id) {
        if (id === 'refresh') {
            this._client.refresh();
        } else if (id === 'settings') {
            this._openSettings();
        } else if (id === 'quit') {
            // Quitting stops everything: the daemon ends, and the surface goes with
            // it — for this session. The extension stays enabled, so the next
            // login, or launching CapaTheNotch, brings it back. Every window
            // closes too (`terminate`): an open Settings asking the daemon
            // again would start it, with no surface.
            this._quitSettings();
            this._client.quit();
            dormant = true;
            GLib.idle_add(GLib.PRIORITY_DEFAULT, () => {
                if (dormant)
                    this._stop();
                return GLib.SOURCE_REMOVE;
            });
        }
    }

    /** Closes Settings and onboarding, if they are open: their program's `quit` action, never starting it. */
    _quitSettings() {
        Gio.DBus.session.call(SETTINGS_NAME, SETTINGS_PATH, 'org.gtk.Actions', 'Activate',
            new GLib.Variant('(sava{sv})', ['quit', [], {}]), null, Gio.DBusCallFlags.NO_AUTO_START, 2000, null,
            (connection, result) => {
                try {
                    connection.call_finish(result);
                } catch (_e) {
                    // Not open: nothing to close.
                }
            });
    }

    /** First run: the welcome, once, when the hub says nothing has been chosen yet. */
    _firstRun(state) {
        if (this._welcomed || !state.modules?.settings?.onboarding?.needed)
            return;
        this._welcomed = true;
        this._openSettings(null, {onboarding: true});
    }

    _place() {
        this._surface.setMonitor(this._glue?.monitor() ?? Main.layoutManager.primaryMonitor);
    }

    _alert(alert) {
        this._glue.alert(alert);
    }

    /**
     * The menu bar item (`MenuBarExtra` in Bootstrap.swift): Kapa's silhouette
     * in the top bar, drawn as a symbolic icon so it takes the bar's own colour,
     * and the menu's three items under it. The panel's manager opens and closes it.
     */
    _addButton() {
        const button = new PanelMenu.Button(0.5, 'CapaTheNotch');
        button.add_child(new St.Icon({
            gicon: Gio.FileIcon.new(this.dir.get_child('icons').get_child('capa-the-notch-symbolic.svg')),
            // 18 points tall, the height of a menu bar item's image; the silhouette is 22 by 18.
            icon_size: 22,
            style_class: 'system-status-icon',
        }));
        this._button = button;
        this._fillMenu(null);
        // The items' shortcuts, while the menu is open. Opened by a click the
        // keyboard is the button's; opened from the keyboard, an item's.
        const shortcut = (_actor, event) => {
            if (!button.menu.isOpen || !(event.get_state() & Clutter.ModifierType.CONTROL_MASK))
                return Clutter.EVENT_PROPAGATE;
            const id = shortcutFor(event.get_key_symbol(), event.get_key_code());
            if (!id)
                return Clutter.EVENT_PROPAGATE;
            button.menu.close();
            this._act(id);
            return Clutter.EVENT_STOP;
        };
        button.menu.actor.connect('key-press-event', shortcut);
        button.connect('key-press-event', shortcut);
        Main.panel.addToStatusArea('capa-the-notch', button);
        this._overSurface(button.menu);
    }

    /** The items, again when the language changes (`word(_:)` reads it at every drawing). */
    _fillMenu(language) {
        if (!this._button || (language && language === this._menuLanguage))
            return;
        this._menuLanguage = language;
        fillMenu(this._button.menu, id => this._act(id));
    }

    /**
     * A menu that drops from the bar is drawn over the surface, which is chrome
     * above every popup: both hang from the top of the screen.
     */
    _overSurface(menu, changed = () => {}) {
        return menu.connect('open-state-changed', (_m, open) => {
            changed(open);
            const surface = this._surface?.actor;
            if (open && surface && menu.actor.get_parent() === surface.get_parent())
                surface.get_parent().set_child_above_sibling(menu.actor, surface);
        });
    }

    /** The date menu, the calendar and the notifications, is the clock's: the surface keeps out of its way while it is open. */
    _watchCalendar() {
        const menu = Main.panel.statusArea.dateMenu?.menu;
        if (!menu)
            return;
        this._calendarOpen = this._overSurface(menu, open => this._surface?.holdClosed(open));
    }

    _unwatchCalendar() {
        if (this._calendarOpen)
            Main.panel.statusArea.dateMenu?.menu.disconnect(this._calendarOpen);
        this._calendarOpen = 0;
    }

    /** A click on the time in the strip: the calendar, as a click on the clock under it opens it. */
    _openCalendar() {
        const menu = Main.panel.statusArea.dateMenu?.menu;
        if (!menu)
            return;
        // The surface lets go first: a pinned one gives the keyboard back before the calendar takes it.
        if (this._surface.expanded)
            this._surface.dismiss();
        // After the click is over: the grab cannot be taken in the middle of it.
        GLib.idle_add(GLib.PRIORITY_DEFAULT, () => {
            if (this._running)
                menu.toggle();
            return GLib.SOURCE_REMOVE;
        });
    }
}
