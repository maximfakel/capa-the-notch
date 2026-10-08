// A file carried to the surface, from another program (Nautilus, a browser).
//
// The Shell is told where a Wayland drag is (`Meta.Dnd`: enter, position, leave) but
// not what it carries, and it has no drop target for it. So for the length of a drag
// a transparent window of drop-catcher.js is stood under the surface, where the drop
// would be, and the surface steps out of its way (it is not reactive meanwhile, so
// that the window beneath is what the pointer is over). What the window sees it says
// in its title (drop-catcher.js), and this turns that into what the surface's
// controller does when a file is carried at a point, dropped, or let go.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GioUnix from 'gi://GioUnix';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';

import {Metrics} from './ui/metrics.js';

const APP = 'tech.capathenotch.DropCatcher';
const DESKTOP_ENTRY = `${APP}.desktop`;
const TITLE = 'capa-drop:';
/** How long the window outlives the drag: the drop is delivered a moment after the button goes up. */
const LINGER_MS = 2500;

export class DndHost {
    /** @param {{surface: object, shelfOn: () => boolean, monitor: () => object}} parts */
    constructor({surface, shelfOn, monitor}) {
        this._surface = surface;
        this._shelfOn = shelfOn;
        this._monitor = monitor;
        this._dragging = false;
        this._files = false;
        this._point = null;
        this._window = null;
        this._titleId = 0;
        this._linger = 0;
        this._fit = 0;
        this._running = false;
        this._pending = null;

        const dnd = global.backend.get_dnd();
        this._dnd = dnd;
        this._signals = [
            [dnd, dnd.connect('dnd-enter', () => this._enter())],
            [dnd, dnd.connect('dnd-position-change', (_d, x, y) => this._position(x, y))],
            [dnd, dnd.connect('dnd-leave', () => this._leave())],
            [global.display, global.display.connect('window-created', (_d, window) => this._created(window))],
        ];
        this._actions = Gio.DBusActionGroup.get(Gio.DBus.session, APP, `/${APP.replaceAll('.', '/')}`);
        // A group of another program's actions is only live once it has been asked what it has.
        this._actions.list_actions();
    }

    /** The program that owns the window: started while the Shelf is on, so that it is there in time. */
    keep(on) {
        if (on === this._running)
            return;
        this._running = on;
        if (on) {
            this._actions.list_actions();
            try {
                GioUnix.DesktopAppInfo.new(DESKTOP_ENTRY)?.launch([], global.create_app_launch_context(0, -1));
            } catch (e) {
                console.error(`capa-the-notch: could not start the drop window: ${e}`);
            }
        } else {
            this._actions.activate_action('quit', null);
        }
    }

    get _controller() {
        return this._surface.controller;
    }

    _enter() {
        if (!this._shelfOn())
            return;
        this._dragging = true;
        this._files = false;
        this._cancelLinger();
        // The window beneath is what the pointer must be over for the drag to reach it.
        this._surface.actor.reactive = false;
        if (this._window)
            this._place();
        this._actions.activate_action('show', null);
        this._fit = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 100, () => {
            this._place();
            return GLib.SOURCE_CONTINUE;
        });
    }

    _position(x, y) {
        this._point = {x, y};
        if (this._dragging && this._files)
            this._controller.fileDrag(this._point);
    }

    _leave() {
        if (!this._dragging)
            return;
        this._dragging = false;
        this._surface.actor.reactive = true;
        if (this._fit)
            GLib.source_remove(this._fit);
        this._fit = 0;
        if (this._files)
            this._controller.fileDragEnded();
        this._files = false;
        this._linger = GLib.timeout_add(GLib.PRIORITY_DEFAULT, LINGER_MS, () => {
            this._linger = 0;
            this._actions.activate_action('hide', null);
            return GLib.SOURCE_REMOVE;
        });
    }

    _cancelLinger() {
        if (this._linger)
            GLib.source_remove(this._linger);
        this._linger = 0;
    }

    /** A window appeared: its class is not known yet, so it is asked again when it is. */
    _created(window) {
        if (window.get_wm_class() === APP) {
            this._adopt(window);
            return;
        }
        const id = window.connect('notify::wm-class', () => {
            window.disconnect(id);
            if (window.get_wm_class() === APP)
                this._adopt(window);
        });
    }

    _adopt(window) {
        this._window = window;
        window.connect('unmanaged', () => {
            if (this._window === window)
                this._window = null;
        });
        this._titleId = window.connect('notify::title', () => this._said(window.get_title() ?? ''));
        // Above the windows it is over (it draws nothing, so it is not seen).
        window.make_above();
        window.stick();
        this._place();
    }

    /** Where the drop would be: the open surface's body, or, closed, the room under the strip that opens it. */
    _place() {
        const window = this._window;
        if (!window || !this._dragging)
            return;
        const scene = this._surface.scene;
        const monitor = this._monitor();
        const bar = scene.geometry.barHeight;
        const cx = monitor.x + monitor.width / 2;
        let rect;
        if (scene.expanded) {
            const width = Math.round(scene.openWidth);
            rect = {x: Math.round(cx - width / 2), y: monitor.y + bar, w: width, h: Math.round(scene.openHeight - bar)};
        } else {
            const width = Math.round(scene.compactWidth + 2 * Metrics.nearDistance);
            rect = {x: Math.round(cx - width / 2), y: monitor.y + bar, w: width, h: Metrics.nearDistance};
        }
        const frame = window.get_frame_rect();
        if (frame.x !== rect.x || frame.y !== rect.y || frame.width !== rect.w || frame.height !== rect.h)
            window.move_resize_frame(true, rect.x, rect.y, rect.w, rect.h);
    }

    _said(title) {
        if (!title.startsWith(TITLE))
            return;
        const what = title.slice(TITLE.length);
        if (what === 'files') {
            this._files = true;
            if (this._point)
                this._controller.fileDrag(this._point);
        } else if (what === 'dropping') {
            this._controller.fileDropped(() => new Promise(resolve => {
                this._pending = resolve;
            }));
        } else if (what === 'added' || what === 'nothing') {
            // Over either way: added (or the adding failed), or let go with nothing
            // the Shelf takes, which ends the drag as one that went elsewhere: no sound, no gulp.
            if (this._pending) {
                this._pending();
                this._pending = null;
            } else if (what === 'nothing') {
                this._controller.fileDragEnded();
            }
        }
    }

    destroy() {
        for (const [object, id] of this._signals)
            object.disconnect(id);
        this._signals = [];
        this._cancelLinger();
        if (this._fit)
            GLib.source_remove(this._fit);
        this._fit = 0;
        if (this._surface?.actor)
            this._surface.actor.reactive = true;
        if (this._running) {
            this._actions.activate_action('quit', null);
            this._running = false;
        }
        this._pending?.();
        this._pending = null;
        this._window = null;
    }
}
