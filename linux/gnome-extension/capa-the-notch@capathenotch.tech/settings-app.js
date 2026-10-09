#!/usr/bin/env -S gjs -m
// The GNOME settings and onboarding window: a GTK window holding the shared
// page (`settings/`) in a WebKit view, with the hub behind it on D-Bus. Run by
// the extension (`gjs -m settings-app.js -- --section=modules`, `--onboarding`, or the desktop entry with a `capa-settings:` URI);
// a second run goes to the window already open. Needs WebKitGTK 6.0 (Arch:
// `webkitgtk-6.0`).

import Adw from 'gi://Adw?version=1';
import Gdk from 'gi://Gdk?version=4.0';
import Gio from 'gi://Gio';
import GioUnix from 'gi://GioUnix';
import GObject from 'gi://GObject';
import GLib from 'gi://GLib';
import Gtk from 'gi://Gtk?version=4.0';

import System from 'system';

import {storedLanguage} from './menu.js';

// WebKit is loaded the old way, with no `await` at the top of the file. A module that
// awaits before it runs the application runs the whole application inside that
// promise's continuation, and no later `await` in it ever gets to continue: the page
// asked the hub for its state, the hub answered, and the answer was never read.
let WebKit = null;
try {
    imports.gi.versions.WebKit = '6.0';
    WebKit = imports.gi.WebKit;
} catch (e) {
    console.error(`capa-the-notch: WebKitGTK 6.0 is needed for the settings window: ${e}`);
}

// The window's icon, found by name in the icon theme (`linux/packaging/icons`, installed beside the extension).
GLib.set_prgname('tech.capathenotch.Settings');
GLib.set_application_name(storedLanguage() === 'ru' ? 'Настройки' : 'Settings');

/**
 * Each window's title, in the language chosen in Settings and again when it
 * changes (`applyLanguage`). Settings is just "Settings", the person's choice
 * over Swift's "CapaTheNotch Settings"; onboarding is Swift's own, its
 * Russian from the hub's table.
 */
const TITLES = {
    settings: {en: 'Settings', ru: 'Настройки'},
    onboarding: {en: 'Welcome to CapaTheNotch', ru: 'Добро пожаловать в CapaTheNotch'},
};

function titleFor(mode, state) {
    const language = state?.language ?? storedLanguage();
    const english = TITLES[mode].en;
    if (language !== 'ru')
        return english;
    return mode === 'onboarding' ? state?.dictionary?.[english] ?? TITLES[mode].ru : TITLES[mode].ru;
}

// macOS draws this window with the system's rounded corners; an undecorated GTK window has
// square ones, so the page is clipped to a rounded shape and the window behind it left clear.
// Clear to the eye, not to GTK: on a fully transparent background its first picture went out
// a commit after its answer to Mutter's first configure, which Mutter logs as a buggy client.
const CORNER_RADIUS = 12;
const STYLE = `
window.capa-settings { background: rgba(0, 0, 0, 0.004); box-shadow: none; }
.capa-clip { border-radius: ${CORNER_RADIUS}px; }
`;

function installStyle() {
    const provider = new Gtk.CssProvider();
    provider.load_from_string(STYLE);
    Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
}

const DIR = GLib.path_get_dirname(import.meta.url.replace('file://', ''));
const SIZE = {width: 760, height: 560};

const SettingsApp = GObject.registerClass(class SettingsApp extends Adw.Application {
    constructor() {
        super({application_id: 'tech.capathenotch.Settings', flags: Gio.ApplicationFlags.HANDLES_COMMAND_LINE});
        this._windows = new Map();
        this._state = null;
        this._client = null;
        this.connect('command-line', (_app, line) => this._commandLine(line));
        // CapaTheNotch quitting closes every window (`terminate`): its menu's Quit
        // activates this over the bus (`org.gtk.Actions`, extension.js).
        const quit = new Gio.SimpleAction({name: 'quit'});
        quit.connect('activate', () => this._quitAll());
        this.add_action(quit);
    }

    _quitAll() {
        for (const entry of [...this._windows.values()])
            entry.window.destroy();
        this._windows.clear();
        this.quit();
    }

    _commandLine(line) {
        const given = line.get_arguments().map(String);
        // From the Shell, by the desktop entry: one `capa-settings:?section=modules&module=dictation` (`onboarding=1`).
        const asked = new Map((given.find(a => a.startsWith('capa-settings:'))?.split('?')[1] ?? '').split('&')
            .filter(Boolean).map(pair => pair.split('=').map(decodeURIComponent)));
        // From a terminal: `--section=modules`, `--onboarding`.
        const args = given.filter(a => a.startsWith('--'));
        const option = name => asked.get(name) ?? args.find(a => a.startsWith(`--${name}=`))?.split('=')[1];
        const onboarding = asked.has('onboarding') || args.includes('--onboarding');
        this.hold();
        this._ensureClient();
        // Only what was asked: no section (the menu's "Settings…") opens a new window on General
        // and leaves an open one where it is (`showSettings(section: nil)`).
        const params = Object.fromEntries(['section', 'module', 'page', 'step']
            .map(name => [name, option(name)]).filter(([, v]) => v !== undefined && v !== ''));
        this._open(onboarding ? 'onboarding' : 'settings', params);
        this.release();
        return 0;
    }

    /**
     * The hub, over D-Bus, with no proxy object: calls, and the signals that carry its state.
     * (A generated proxy never finished its introspection inside this GTK program.)
     */
    _ensureClient() {
        if (this._client)
            return;
        const BUS = 'tech.capathenotch.Daemon', PATH = '/tech/capathenotch/Daemon', IFACE = 'tech.capathenotch.Daemon1';
        const session = Gio.DBus.session;
        const call = (method, params, replyType) => new Promise((resolve, reject) => {
            // Never starting the daemon: one that quit stays quit, and this window says it is not running.
            session.call(BUS, PATH, IFACE, method, params, replyType, Gio.DBusCallFlags.NO_AUTO_START, -1, null, (_c, res) => {
                if (GLib.getenv('CAPA_SETTINGS_SCRIPT'))
                    console.error(`capa-the-notch settings: answered ${method}`);
                try {
                    resolve(session.call_finish(res));
                } catch (e) {
                    reject(e);
                }
            });
            if (GLib.getenv('CAPA_SETTINGS_SCRIPT'))
                console.error(`capa-the-notch settings: asked ${method}`);
        });
        const fetch = async () => {
            if (GLib.getenv('CAPA_SETTINGS_SCRIPT'))
                console.error('capa-the-notch settings: fetching the state');
            try {
                const [json] = (await call('GetState', null, new GLib.VariantType('(s)'))).deepUnpack();
                this._state = JSON.parse(json);
                if (GLib.getenv('CAPA_SETTINGS_SCRIPT'))
                    console.error(`capa-the-notch settings: state fetched, ${json.length} bytes, windows=${this._windows.size}`);
                this._windows.forEach(w => this._push(w, this._state));
            } catch (e) {
                this._state = null;
                console.error(`capa-the-notch: the hub did not answer: ${e.message}`);
                // The page draws "capa-daemon is not running…" for no state, rather than nothing.
                this._windows.forEach(w => this._push(w, null));
            }
        };
        const subscribe = (signal, handler) => session.signal_subscribe(BUS, IFACE, signal, PATH, null, Gio.DBusSignalFlags.NONE, handler);
        subscribe('StateChanged', (_c, _s, _p, _i, _n, params) => {
            this._state = JSON.parse(params.deepUnpack()[0]);
            this._windows.forEach(w => this._push(w, this._state));
        });
        subscribe('ModuleEvent', (_c, _s, _p, _i, _n, params) => {
            const [module, name, data] = params.deepUnpack();
            this._windows.forEach(w => this._script(w.view,
                `window.__capaEvent(${JSON.stringify(module)}, ${JSON.stringify(name)}, ${JSON.stringify(data)})`));
        });
        // The daemon coming back (it was restarted) is a reason to ask again; its going is not.
        session.signal_subscribe('org.freedesktop.DBus', 'org.freedesktop.DBus', 'NameOwnerChanged', '/org/freedesktop/DBus', BUS,
            Gio.DBusSignalFlags.NONE, (_c, _s, _p, _i, _n, params) => {
                const [, , owner] = params.deepUnpack();
                if (owner)
                    fetch();
            });
        this._client = {
            fetch,
            call: async (module, method, args) => {
                const [json] = (await call('Call', new GLib.Variant('(sss)', [module, method, JSON.stringify(args)]),
                    new GLib.VariantType('(s)'))).deepUnpack();
                const answer = JSON.parse(json);
                if ('error' in answer)
                    throw new Error(answer.error);
                return answer.ok;
            },
        };
        // Not from inside the command-line handler: the first call made there never came back.
        GLib.idle_add(GLib.PRIORITY_DEFAULT, () => {
            fetch();
            return GLib.SOURCE_REMOVE;
        });
    }

    _open(mode, params) {
        const existing = this._windows.get(mode);
        if (existing) {
            // Still drawing its first picture: it shows as soon as it has one.
            if (existing.shown)
                existing.window.present();
            // Asked for a section, it goes there, with the card and the page asked for.
            if (params.section) {
                const {section, module, page} = params;
                this._script(existing.view, `window.__capaGo && window.__capaGo(${JSON.stringify({section, module, page})})`);
            }
            return;
        }
        if (!WebKit) {
            const dialog = new Adw.MessageDialog({
                heading: 'WebKitGTK 6.0 is needed',
                body: 'The settings window is drawn with WebKitGTK. Install it (Arch: sudo pacman -S webkitgtk-6.0) and open Settings again.',
            });
            dialog.add_response('ok', 'OK');
            dialog.present();
            return;
        }

        const context = new WebKit.UserContentManager();
        context.register_script_message_handler('capa', null);
        const settings = new WebKit.Settings({enable_developer_extras: false});
        // On the GPU: drawn in software the page cannot keep up with a high refresh rate
        // (a 2560-wide window at 180 Hz stutters). CAPA_SETTINGS_HWACCEL=never to compare.
        if (GLib.getenv('CAPA_SETTINGS_HWACCEL') === 'never')
            settings.set_hardware_acceleration_policy(WebKit.HardwareAccelerationPolicy.NEVER);
        settings.set_allow_file_access_from_file_urls(true);
        settings.set_allow_universal_access_from_file_urls(true);
        const view = new WebKit.WebView({user_content_manager: context, settings, hexpand: true, vexpand: true});
        // GNOME's own scheme, which libadwaita follows: the page wears it before the state arrives,
        // and the view starts in the page's window colour, so nothing white is ever seen.
        const styles = Adw.StyleManager.get_default();
        const scheme = () => (styles.get_dark() ? 'dark' : 'light');
        view.set_background_color(scheme() === 'dark'
            ? new Gdk.RGBA({red: 0x17 / 255, green: 0x17 / 255, blue: 0x17 / 255, alpha: 1})
            : new Gdk.RGBA({red: 0xFA / 255, green: 0xFA / 255, blue: 0xFA / 255, alpha: 1}));
        const entry = {mode, view, loaded: false, shown: false};

        const window = new Gtk.ApplicationWindow({
            application: this, default_width: SIZE.width, default_height: SIZE.height, resizable: false,
            title: titleFor(mode, this._state), decorated: false,
        });
        entry.window = window;
        // The page's top edge moves the window; the close button at the right stays the page's own.
        installStyle();
        window.add_css_class('capa-settings');
        const overlay = new Gtk.Overlay({child: view});
        overlay.add_css_class('capa-clip');
        overlay.set_overflow(Gtk.Overflow.HIDDEN);
        // Over the sidebar's empty top always; over the content's top only while the page is not
        // scrolled, so a control scrolled up there still takes its click (the page says, `scrolled`).
        const side = new Gtk.WindowHandle({halign: Gtk.Align.START, valign: Gtk.Align.START, width_request: 200, height_request: 52});
        const top = new Gtk.WindowHandle({halign: Gtk.Align.FILL, valign: Gtk.Align.START, height_request: 52, margin_start: 200, margin_end: 56});
        overlay.add_overlay(side);
        overlay.add_overlay(top);
        entry.topHandle = top;
        window.set_icon_name('tech.capathenotch.CapaTheNotch');
        window.set_child(overlay);
        // "System" follows GNOME while the window is open.
        const darkChanged = styles.connect('notify::dark', () =>
            this._script(view, `window.dispatchEvent(new CustomEvent('capa-scheme', {detail: '${scheme()}'}))`));
        window.connect('close-request', () => {
            styles.disconnect(darkChanged);
            this._windows.delete(mode);
            return false;
        });

        context.connect('script-message-received::capa', (_m, value) => this._message(entry, JSON.parse(value.to_string())));
        view.connect('load-changed', (_v, event) => {
            if (event === WebKit.LoadEvent.FINISHED) {
                entry.loaded = true;
                if (this._state)
                    this._push(entry, this._state);
                // For trying the page without a hand: JavaScript to run once it is up.
                const script = GLib.getenv('CAPA_SETTINGS_SCRIPT');
                if (script)
                    GLib.timeout_add(GLib.PRIORITY_DEFAULT, 1500, () => { this._script(view, script); return GLib.SOURCE_REMOVE; });
            }
        });
        const query = Object.entries({mode, scheme: scheme(), ...params}).filter(([, v]) => v !== undefined)
            .map(([k, v]) => `${k}=${encodeURIComponent(v)}`).join('&');
        view.load_uri(`file://${DIR}/settings/${GLib.getenv('CAPA_SETTINGS_PAGE') ?? 'index.html'}?${query}`);
        this._windows.set(mode, entry);
        // Shown once the page has drawn its first picture (`painted`), as a Mac window comes up with
        // its content; a page that never says so still shows after a moment.
        entry.show = () => {
            if (entry.shown || !this._windows.has(mode))
                return;
            entry.shown = true;
            window.present();
        };
        GLib.timeout_add(GLib.PRIORITY_DEFAULT, 1500, () => {
            entry.show();
            return GLib.SOURCE_REMOVE;
        });
    }

    /**
     * Shows a file selected in the file manager (`activateFileViewerSelecting`):
     * `org.freedesktop.FileManager1.ShowItems`, or the folder it is in where no
     * file manager answers that.
     */
    _reveal(path) {
        const folder = () => {
            try {
                Gio.AppInfo.launch_default_for_uri(Gio.File.new_for_path(GLib.path_get_dirname(path)).get_uri(), null);
            } catch (e) {
                console.error(`capa-the-notch: could not reveal ${path}: ${e}`);
            }
        };
        Gio.DBus.session.call('org.freedesktop.FileManager1', '/org/freedesktop/FileManager1', 'org.freedesktop.FileManager1',
            'ShowItems', new GLib.Variant('(ass)', [[Gio.File.new_for_path(path).get_uri()], '']), null,
            Gio.DBusCallFlags.NONE, 5000, null, (c, res) => {
                try {
                    c.call_finish(res);
                } catch (e) {
                    folder();
                }
            });
    }

    _push(entry, state) {
        if (GLib.getenv('CAPA_SETTINGS_SCRIPT'))
            console.error(`capa-the-notch settings: push loaded=${entry.loaded}`);
        // The title follows the language before the page can, as AppKit's does (`applyLanguage`).
        if (state)
            entry.window.title = titleFor(entry.mode, state);
        if (!entry.loaded)
            return;
        // No hub, no language from it: the page is told the one last chosen, to say so in it.
        const hint = state ? '' : `, ${JSON.stringify(JSON.stringify({language: storedLanguage()}))}`;
        this._script(entry.view, `window.__capaState(${JSON.stringify(JSON.stringify(state))}${hint})`);
    }

    _script(view, source) {
        view.evaluate_javascript(source, -1, null, null, null, null);
    }

    _reply(entry, id, ok, payload) {
        const json = payload === undefined || payload === null ? '' : JSON.stringify(payload);
        this._script(entry.view, `window.__capaReply(${id}, ${ok}, ${JSON.stringify(ok ? json : String(payload))})`);
    }

    async _message(entry, message) {
        if (GLib.getenv('CAPA_SETTINGS_SCRIPT'))
            console.error(`capa-the-notch settings: message ${message.kind} ${message.module ?? ''} ${message.method ?? ''}`);
        switch (message.kind) {
        case 'background': {
            // The page's colour (`rgb(...)`/`rgba(...)`), for what lies behind the page.
            const parts = String(message.color).match(/[\d.]+/g)?.map(Number);
            if (parts && parts.length >= 3) {
                const [r, g, b, a = 1] = parts;
                entry.view.set_background_color(new Gdk.RGBA({red: r / 255, green: g / 255, blue: b / 255, alpha: a}));
            }
            break;
        }
        case 'painted':
            entry.show?.();
            break;
        case 'ready':
            // The page can take the state now (see host-webkit.js).
            entry.loaded = true;
            if (this._state)
                this._push(entry, this._state);
            else
                this._client?.fetch();
            break;
        case 'call':
            try {
                // `settings.set`, `hub.diagnosticReport`: the hub's own commands.
                const answer = await this._client.call(message.module, message.method, message.args);
                this._reply(entry, message.id, true, answer);
            } catch (e) {
                this._reply(entry, message.id, false, e.message ?? e);
            }
            break;
        case 'openUrl':
            try {
                Gio.AppInfo.launch_default_for_uri(message.url, null);
            } catch (e) {
                console.error(`capa-the-notch: could not open ${message.url}: ${e}`);
            }
            break;
        case 'copy':
            Gdk.Display.get_default().get_clipboard().set(message.text);
            break;
        case 'reveal':
            this._reveal(message.path);
            break;
        case 'paste': {
            // The clipboard as GTK has it (`NSPasteboard.general.string`): text, or nothing.
            const clipboard = Gdk.Display.get_default().get_clipboard();
            clipboard.read_text_async(null, (c, res) => {
                let text = null;
                try {
                    text = c.read_text_finish(res);
                } catch (e) {
                    text = null;
                }
                this._reply(entry, message.id, true, text ?? '');
            });
            break;
        }
        case 'appNames': {
            // The application's own name, or nothing if it is gone (the page shows the identifier then).
            const names = {};
            for (const id of message.ids ?? []) {
                try {
                    const name = GioUnix.DesktopAppInfo.new(`${id}.desktop`)?.get_display_name();
                    if (name)
                        names[id] = name;
                } catch (e) {
                    // Not installed: no name.
                }
            }
            this._reply(entry, message.id, true, names);
            break;
        }
        case 'scrolled':
            entry.topHandle?.set_visible(!message.scrolled);
            break;
        case 'pick': {
            const dialog = new Gtk.AppChooserDialog({transient_for: entry.window, modal: true});
            dialog.connect('response', (d, response) => {
                const id = response === Gtk.ResponseType.OK ? d.get_app_info()?.get_id()?.replace(/\.desktop$/, '') : null;
                d.destroy();
                this._reply(entry, message.id, true, id ? [id] : []);
            });
            dialog.present();
            break;
        }
        case 'log':
            console.error(`capa-the-notch settings page: ${message.text}`);
            break;
        case 'close':
            entry.window.close();
            break;
        default:
            break;
        }
    }
});

new SettingsApp().run([System.programInvocationName, ...System.programArgs]);
