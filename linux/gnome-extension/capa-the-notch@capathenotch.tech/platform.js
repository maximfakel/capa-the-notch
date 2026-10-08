// What GNOME knows that the hub cannot: which monitors there are and which
// one holds the surface, whether a fullscreen application is in front, and how
// an alert reaches the person and brings them back to the window it was about.

import GLib from 'gi://GLib';
import Meta from 'gi://Meta';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as MessageTray from 'resource:///org/gnome/shell/ui/messageTray.js';

/** How long the row an alert was about stays pointed at. */
const HIGHLIGHT_SECONDS = 6;

/**
 * Whether CapaTheNotch starts at login (`LaunchAtLogin.swift`): its autostart
 * entry is there and not switched off in the desktop's own startup settings.
 * Read the way `capa_platform::launch_at_login` reads it.
 */
export function launchesAtLogin() {
    try {
        const path = GLib.build_filenamev([GLib.get_user_config_dir(), 'autostart', 'capa-the-notch.desktop']);
        const [ok, bytes] = GLib.file_get_contents(path);
        if (!ok)
            return false;
        const lines = new TextDecoder().decode(bytes).split('\n').map(line => line.trim());
        return !lines.includes('Hidden=true') && !lines.includes('X-GNOME-Autostart-enabled=false');
    } catch (_e) {
        return false;
    }
}

/** A stable number for a monitor: FNV-1a of its connector's name. */
export function monitorId(name) {
    let hash = 0x811c9dc5;
    for (const c of String(name)) {
        hash ^= c.codePointAt(0);
        hash = Math.imul(hash, 0x01000193) >>> 0;
    }
    return hash >>> 0;
}

export class PlatformGlue {
    /** @param {{client: object, surface: object, place: () => void}} parts */
    constructor({client, surface, place}) {
        this._client = client;
        this._surface = surface;
        this._place = place;
        this._chosen = null;
        this._notifications = new Map();
        this._source = null;
        this._highlight = 0;

        this._signals = [
            [Main.layoutManager, Main.layoutManager.connect('monitors-changed', () => this.report())],
            [global.display, global.display.connect('in-fullscreen-changed', () => this._fullscreen())],
            [global.display, global.display.connect('window-created', (_d, window) => this._watch(window))],
            [global.display, global.display.connect('notify::focus-window', () => this._later())],
            [global.workspace_manager, global.workspace_manager.connect('active-workspace-changed', () => this._later())],
        ];
        // A window opened to the whole screen covers what the surface shows under the strip, as a fullscreen one does.
        this._windows = new Map();
        this._pending = 0;
        for (const actor of global.get_window_actors())
            this._watch(actor.meta_window);
    }

    /** The monitors, as the hub wants them: `{id, name, isBuiltIn}` and, for placing, the monitor itself. */
    describe() {
        const manager = global.backend.get_monitor_manager();
        const logical = manager.get_logical_monitors();
        return Main.layoutManager.monitors.map(monitor => {
            // A logical monitor knows its number, the layout manager's index, not where it is.
            const at = logical.find(l => l.get_number() === monitor.index);
            const physical = at?.get_monitors?.()[0];
            const connector = physical?.get_connector?.() ?? `monitor-${monitor.index}`;
            const isBuiltIn = physical?.is_builtin?.() ?? false;
            let name = physical?.get_display_name?.() ?? physical?.get_connector?.() ?? `Display ${monitor.index + 1}`;
            // GNOME calls a laptop's own panel "Built-in display" — the very words of the
            // choice above the screens in Settings ("Show on"), where the Mac's panel has a
            // name of its own ("Built-in Retina Display"). Its connector tells the two apart.
            if (isBuiltIn && physical?.get_connector?.())
                name = `${name} (${connector})`;
            return {id: monitorId(connector), name, isBuiltIn, monitor};
        });
    }

    /** Tells the hub which monitors there are now; it chooses which holds the surface. */
    report() {
        this._client.setDisplays(this.describe().map(({id, name, isBuiltIn}) => ({id, name, isBuiltIn})));
        this._place();
    }

    /** The monitor the hub chose, or the primary one while it has not said. */
    monitor() {
        const wanted = this._chosen;
        return this.describe().find(d => d.id === wanted)?.monitor ?? Main.layoutManager.primaryMonitor;
    }

    /** The hub's state: the choice of display may have changed. */
    state(state) {
        const chosen = state?.displays?.chosenId ?? null;
        if (chosen !== this._chosen) {
            this._chosen = chosen;
            this._place();
        }
        this._fullscreen();
    }

    /** Over a fullscreen application, or a window opened to the whole screen, the closed surface is the strip alone. */
    _fullscreen() {
        const monitor = this.monitor();
        this._surface.setFullscreen(!!monitor &&
            (global.display.get_monitor_in_fullscreen(monitor.index) || this._covered(monitor)));
    }

    /** A maximized window, in view, on the surface's monitor. */
    _covered(monitor) {
        const workspace = global.workspace_manager.get_active_workspace();
        return workspace.list_windows().some(window =>
            window.get_monitor() === monitor.index && !window.minimized &&
            window.get_window_type() === Meta.WindowType.NORMAL &&
            window.maximized_horizontally && window.maximized_vertically);
    }

    _watch(window) {
        if (!window || this._windows.has(window))
            return;
        const ids = ['notify::maximized-horizontally', 'notify::maximized-vertically', 'notify::minimized',
            'workspace-changed', 'notify::monitor']
            .map(name => {
                try {
                    return window.connect(name, () => this._later());
                } catch (_e) {
                    return 0;
                }
            });
        ids.push(window.connect('unmanaged', () => {
            this._windows.delete(window);
            this._later();
        }));
        this._windows.set(window, ids.filter(Boolean));
        this._later();
    }

    /** Several signals say one thing; ask once, after them. */
    _later() {
        if (this._pending)
            return;
        this._pending = GLib.idle_add(GLib.PRIORITY_DEFAULT, () => {
            this._pending = 0;
            this._fullscreen();
            return GLib.SOURCE_REMOVE;
        });
    }

    /**
     * An alert reaches the person as a notification, one per window and
     * replaced rather than stacked, so a Provider cannot fill the tray. The
     * banner is silent: its sound is CapaTheNotch's own, played by the hub.
     * Activating it opens the surface, pinned, with that row pointed at.
     */
    alert(alert) {
        this._source ??= this._makeSource();
        const key = `${alert.provider}.${alert.windowId}`;
        this._notifications.get(key)?.destroy();
        const notification = new MessageTray.Notification({
            source: this._source, title: alert.title, body: alert.body, isTransient: false,
        });
        notification.connect('activated', () => this.openAlert(alert.provider, alert.windowId));
        notification.connect('destroy', () => {
            if (this._notifications.get(key) === notification)
                this._notifications.delete(key);
        });
        this._notifications.set(key, notification);
        this._source.addNotification(notification);
    }

    _makeSource() {
        const source = new MessageTray.Source({title: 'CapaTheNotch', iconName: 'tech.capathenotch.CapaTheNotch'});
        source.connect('destroy', () => {
            this._source = null;
            this._notifications.clear();
        });
        Main.messageTray.add(source);
        return source;
    }

    /** Brings someone back to the window an alert was about: the surface opens, pinned, with that row pointed at for a few seconds. */
    openAlert(provider, windowId) {
        this._surface.openAlert(provider, windowId);
        if (this._highlight)
            GLib.source_remove(this._highlight);
        this._highlight = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, HIGHLIGHT_SECONDS, () => {
            this._highlight = 0;
            this._surface.highlight(null);
            return GLib.SOURCE_REMOVE;
        });
    }

    destroy() {
        for (const [object, id] of this._signals)
            object.disconnect(id);
        this._signals = [];
        if (this._pending)
            GLib.source_remove(this._pending);
        this._pending = 0;
        for (const [window, ids] of this._windows) {
            for (const id of ids)
                window.disconnect(id);
        }
        this._windows.clear();
        if (this._highlight)
            GLib.source_remove(this._highlight);
        this._highlight = 0;
        this._source?.destroy();
        this._source = null;
        this._notifications.clear();
    }
}
