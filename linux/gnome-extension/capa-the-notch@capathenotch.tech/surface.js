// The Notch Surface on GNOME Shell: one drawing area that follows the shape
// and runs the shared scene on Cairo and Pango. All that is drawn, and how it
// moves, is in `ui/`; this file gives the
// scene a context, a clock and the pointer, and gives the shell its actions.

import Atk from 'gi://Atk';
import Cairo from 'gi://cairo';
import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import St from 'gi://St';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';

import {Gfx} from './ui/gfx.js';
import {SurfaceScene} from './ui/scene.js';
import {SurfaceController} from './ui/controller.js';
import {deriveModel, sameValue} from './ui/model.js';
import {FrameChain, FRAME_MS, KAPA_FRAME_MS} from './ui/frames.js';
import {setClockFormat, setLanguage} from './ui/format.js';
import {setDictionary} from './ui/strings.js';
import {Metrics} from './ui/metrics.js';
import {CairoGjs} from './ui/kapa/cairo-gjs.js';
import {PangoText} from './pango-text.js';
import {t} from './ui/strings.js';

/** Work that takes this long is said in the journal (`_watchSlow`). */
const SLOW_MS = 150;

/** Touchpad deltas from mutter are a tenth of the points the fingers moved. */
const FINGER_POINTS = 10;
/** How long a swipe may go without a word before it is taken to have ended. */
const SWIPE_QUIET_MS = 350;
/** The room a layer keeps round what it draws, for the edges' antialiasing. */
const LAYER_PAD = 2;
/**
 * A layer's left edge falls on a column of the surface a multiple of this many points
 * along: Cairo lays pixels down four at a time, and a picture laid down from a column
 * out of step with the surface's comes out a shade different here and there.
 */
const LAYER_STEP = 4;
/** The layers' order over the surface, as the scene draws them: the row's, a page's Kapa, what hangs under the shape. */
const LAYER_ORDER = {row: 0, kapa: 1, overlay: 2};

/**
 * The drawing area, which takes the pointer only over the shape and what hangs
 * under it: everywhere else in its box — the shoulders, the room kept for the
 * spring's overshoot — the pointer reaches what is underneath (the top bar), as
 * the Mac's panel `ignoresMouseEvents` outside `overSurface`. `pickRects()`
 * says where, in the actor's own coordinates.
 */
const SurfaceArea = GObject.registerClass(
class CapaSurfaceArea extends St.DrawingArea {
    _init(params) {
        super._init(params);
        this.pickRects = () => [];
        this._box = new Clutter.ActorBox();
    }

    /** A drawing area places no children: each layer stands where it is put, at its own size. */
    vfunc_allocate(box) {
        super.vfunc_allocate(box);
        for (const child of this.get_children())
            child.allocate_preferred_size(child.x, child.y);
    }

    vfunc_pick(context) {
        if (!this.reactive)
            return;
        const width = this.width, height = this.height;
        for (const r of this.pickRects()) {
            const x1 = Math.max(r.x, 0), y1 = Math.max(r.y, 0);
            const x2 = Math.min(r.x + r.w, width), y2 = Math.min(r.y + r.h, height);
            if (x2 <= x1 || y2 <= y1)
                continue;
            this._box.init(x1, y1, x2, y2);
            this.pick_box(context, this._box);
        }
    }
});

/**
 * What a screen reader finds over one thing the scene drew (`scene.accessibleNodes()`):
 * a button, a page, words. It is never drawn and never picked — the surface's own
 * `vfunc_pick` covers only the shape, and it takes no pointer — so it is only its place,
 * its name and its role.
 */
const AccessibleNode = GObject.registerClass(
class CapaAccessibleNode extends St.Widget {
    _init() {
        super._init({reactive: false, can_focus: false, track_hover: false, visible: false});
        /** What it was last told, so a drawing that changes nothing changes nothing here. */
        this.said = {selected: false, description: '', focused: false};
    }

    vfunc_paint(_context) {
        // Nothing to draw: the surface draws it all.
    }
});

const ROLES = {button: Atk.Role.PUSH_BUTTON, label: Atk.Role.LABEL, tab: Atk.Role.PAGE_TAB};

export class Surface {
    /**
     * @param {object} host what the surface asks of the rest of the extension
     * @param {() => number} host.barHeight the top bar's height
     * @param {(expanded: boolean) => void} host.setExpanded
     * @param {() => void} host.refresh
     * @param {(provider: string) => void} host.connect
     * @param {() => void} host.openSettings
     * @param {() => void} host.openCalendar the desktop's own clock menu, which the surface covers
     */
    constructor(host) {
        this._host = host;
        this._monitor = {x: 0, y: 0, width: 1920, height: 1080};
        // The desktop's font changing moves the chip and the glyphs: all of it is drawn again.
        this._text = new PangoText({onChange: () => this._wake()});
        this._beat = 0;
        this._width = 0;
        this._height = 0;

        this.scene = new SurfaceScene({barHeight: host.barHeight(), notchWidth: 0}, {
            refresh: provider => host.refresh(provider),
            connect: provider => host.connect(provider),
            openSettings: asked => host.openSettings(asked),
            call: (module, method, args) => host.call(module, method, args),
            decodeImage: base64 => this._decodeImage(base64),
            readClipboard: () => host.readClipboard(),
            writeClipboard: text => host.writeClipboard?.(text),
            startFileDrag: path => host.startFileDrag?.(path),
            sound: cue => host.playSound?.(cue),
            openCalendar: () => host.openCalendar?.(),
            togglePin: () => {
                this.scene.togglePin();
                host.playSound?.('surfacePinned');
                if (this.scene.pinned)
                    this._takeFocus();
                this._wake();
            },
        });
        this.scene.onPresentation = expanded => host.setExpanded(expanded);
        /** Something of the desktop's is open under the bar (the calendar): the surface stays closed and out of its way. */
        this._heldClosed = false;
        // A state arriving does not bring forward a frame already coming (`setState`).
        this.scene.onChange = () => this._wake(this._arriving ? KAPA_FRAME_MS : FRAME_MS);
        // A state that changes only what one layer draws (the voice's level under the capsule) draws that layer alone.
        this.scene.onLayerChange = key => this._frames.schedule(FRAME_MS, key, KAPA_FRAME_MS);
        this._arriving = false;
        // Fades begun between frames start when they were asked for.
        this.scene.time = () => GLib.get_monotonic_time() / 1e6;

        // Pictures the Modules ask for (the Shelf's thumbnails): PNG files the hub wrote where only this user reads.
        const pictures = new Map();
        const missing = new Map();
        this.scene.images = {
            get(path) {
                if (!pictures.has(path)) {
                    // A file not there yet is asked for again after a second, not remembered as missing.
                    const now = GLib.get_monotonic_time();
                    if (now - (missing.get(path) ?? -Infinity) < 1e6)
                        return null;
                    let surface;
                    try {
                        surface = Cairo.ImageSurface.createFromPNG(path);
                    } catch (_e) {
                        if (missing.size >= 256)
                            missing.clear();
                        missing.set(path, now);
                        return null;
                    }
                    // Pictures of Shelf items long gone must not pile up.
                    if (pictures.size >= 256)
                        pictures.clear();
                    pictures.set(path, surface);
                }
                return pictures.get(path);
            },
        };

        this.actor = new SurfaceArea({
            name: 'capa-the-notch', reactive: true, can_focus: true, track_hover: true,
            // What a screen reader says of it: the strip is the one control the closed surface is.
            accessible_name: t('Show or hide Capacity details'),
            accessible_role: Atk.Role.TOGGLE_BUTTON,
        });
        this.actor.pickRects = () => this._pickRects();
        this.actor.connect('repaint', () => {
            this._paint();
            this._frames.painted('whole');
            this._queueSaid();
        });
        /** The accessible objects over what the scene drew, kept and reused in drawing order. */
        this._said = [];
        this._saidIdle = 0;
        this._description = '';
        this._saidOpen = false;
        /** Presses anywhere on the screen, heard while a Module asks (the Dictation popover). */
        this._outsideId = 0;
        // What moves while the rest is still on layers of their own: the closed row's bars
        // or Kapa, the Script's lines, a Kapa on the open page, the Dictation capsule.
        // While only they move, only these small areas are drawn again, and the top bar
        // under the surface is left as it is (`scene.layers`). Kept by key, hidden while
        // not in use; the surface's own `vfunc_pick` leaves them out.
        this._layers = new Map();
        this.scene.liveLayers = true;
        this._screenFrames();
        this._frames = new FrameChain(this.scene, {
            clock: () => GLib.get_monotonic_time() / 1000,
            set: (fn, ms) => GLib.timeout_add(GLib.PRIORITY_DEFAULT, ms, () => { fn(); return GLib.SOURCE_REMOVE; }),
            clear: id => GLib.source_remove(id),
            nextFrame: fn => this._nextFrame(fn),
            clearFrame: id => this._clearFrame(id),
            drawWhole: () => {
                this._layout();
                this.actor.queue_repaint();
            },
            drawLayer: key => this._layers.get(key)?.area.queue_repaint(),
            placeLayers: () => this._placeLayers(),
        });
        this._events = [
            this.actor.connect('button-press-event', (_a, event) => this._press(event)),
            this.actor.connect('motion-event', (_a, event) => this._motion(event)),
            this.actor.connect('button-release-event', (_a, event) => this._release(event)),
            this.actor.connect('leave-event', () => {
                this.scene.setShapePointer(null);
                return this._release(null);
            }),
            this.actor.connect('scroll-event', (_a, event) => this._scroll(event)),
            this.actor.connect('key-press-event', (_a, event) => this._key(event)),
            // A pinned surface lets go when the keyboard goes elsewhere (`windowDidResignKey`).
            this.actor.connect('key-focus-out', () => {
                if (this.scene.pinned)
                    this.focusLost();
            }),
        ];
        this._focusWindowId = global.display.connect('notify::focus-window', () => {
            const window = global.display.focus_window;
            // Taking the keyboard may leave no window focused; a window that takes it is a click elsewhere.
            if (this.scene.pinned && window && window !== this._returnFocus)
                this.focusLost();
        });
        this._workAreasId = global.display.connect('workareas-changed', () => this.setMonitor(this._monitor));
        // The Shell quitting destroys its actors without disabling extensions: the surface
        // lets go of everything then, rather than answer signals over disposed objects.
        this.actor.connect('destroy', () => this.destroy({fromActor: true}));
        this._wasPinned = false;
        this._watchSlow();

        // Touchpad scrolling follows the person's setting; the surface reads the fingers, not the content.
        try {
            this._touchpad = new Gio.Settings({schema_id: 'org.gnome.desktop.peripherals.touchpad'});
        } catch (_e) {
            this._touchpad = null;
        }
        this._swiping = false;
        this._swipeQuiet = 0;

        this.controller = new SurfaceController(this.scene, {
            pointer: () => {
                const [x, y] = global.get_pointer();
                return {x, y};
            },
            buttons: () => (global.get_pointer()[2] & Clutter.ModifierType.BUTTON1_MASK) !== 0,
            monitor: () => this._monitor,
            window: () => ({x: this.actor.x, y: this.actor.y}),
            timers: {
                set: (fn, ms) => GLib.timeout_add(GLib.PRIORITY_DEFAULT, ms, () => { fn(); return GLib.SOURCE_REMOVE; }),
                clear: id => { if (id) GLib.source_remove(id); },
            },
        });
        this.controller.hoverOpens = () => !this._heldClosed && this.scene.hoverOpens();
        // The pointer is read on a beat, as macOS does it, rather than waiting to be told.
        this._beat = GLib.timeout_add(GLib.PRIORITY_DEFAULT, Metrics.pointerInterval * 1000, () => {
            // What the read changes wakes the frame loop itself (`scene.onChange`);
            // a beat that changes nothing draws nothing.
            this.controller.read();
            return GLib.SOURCE_CONTINUE;
        });
        this._layout();
        this._keepTime();
    }

    /**
     * The time in the middle of the strip, where the Mac has its camera and this
     * screen has room. It follows the desktop's own 12 or 24 hours and changes on the minute.
     */
    _keepTime() {
        let interface_ = null;
        try {
            interface_ = new Gio.Settings({schema_id: 'org.gnome.desktop.interface'});
        } catch (_e) {
            // No such schema: 24 hours.
        }
        const show = () => {
            const twelve = interface_?.get_string('clock-format') === '12h';
            // The Shelf's and Music's times follow the desktop's clock too, as Swift's follow the
            // system's; a gauge's reset time keeps the language's own (`languageClock`).
            setClockFormat(interface_ ? twelve : null);
            const now = GLib.DateTime.new_now_local();
            this.scene.setClock(now.format(twelve ? '%l:%M %p' : '%H:%M').trim());
            this._wake();
        };
        const next = () => {
            const left = 60 - GLib.DateTime.new_now_local().get_second();
            this._clockTimer = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, Math.max(left, 1), () => {
                show();
                next();
                return GLib.SOURCE_REMOVE;
            });
        };
        this._clockFormat = interface_?.connect('changed::clock-format', show);
        // Reduce Motion is the desktop's animations turned off (Settings ▸ Accessibility ▸ Seeing).
        const motion = () => {
            this.scene.setModel({reduceMotion: interface_?.get_boolean('enable-animations') === false});
            this._wake();
        };
        this._animationsId = interface_?.connect('changed::enable-animations', motion);
        // The desktop's own light or dark, for what follows the system (the Dictation capsule).
        const scheme = () => {
            this.scene.setModel({systemDark: interface_?.get_string('color-scheme') === 'prefer-dark'});
            this._wake();
        };
        this._schemeId = interface_?.connect('changed::color-scheme', scheme);
        scheme();
        this._interface = interface_;
        motion();
        show();
        next();
    }

    get pinned() { return this.scene.pinned; }
    get expanded() { return this.scene.expanded; }

    setMonitor(monitor) {
        if (!monitor)
            return;
        this._monitor = monitor;
        // The open surface is never taller than the room the screen leaves it (`visibleFrame`).
        let maxHeight = monitor.height;
        try {
            if (monitor.index !== undefined)
                maxHeight = Main.layoutManager.getWorkAreaForMonitor(monitor.index).height;
        } catch (_e) {
            // Not known yet: the monitor's own height.
        }
        this.scene.setGeometry({barHeight: this._host.barHeight(), notchWidth: 0, maxHeight});
        this._layout();
    }

    setRunning(running) {
        this._running = running;
        this.scene.setModel({daemonRunning: running});
    }

    /**
     * The hub's state. One that changes nothing the surface shows draws nothing;
     * one that does is drawn on the frame already coming, if one comes within a
     * Kapa frame, and otherwise on the next — at once if a motion begins with it.
     */
    setState(state) {
        let words = false;
        if (state.dictionary && !sameValue(state.dictionary, this._dictionary)) {
            this._dictionary = state.dictionary;
            setDictionary(state.dictionary);
            this.actor.accessible_name = t('Show or hide Capacity details');
            words = true;
        }
        setLanguage(state.language ?? 'en');
        const model = deriveModel(state, {daemonRunning: true});
        if (!words && !this.scene.differs(model))
            return;
        const resting = this.scene.atRest;
        this._arriving = true;
        try {
            this.scene.setModel(model);
        } finally {
            this._arriving = false;
        }
        if (resting && !this.scene.atRest)
            this._wake();
    }

    /** A fullscreen application is in front: the closed surface is the strip alone. */
    setFullscreen(fullscreen) {
        // The Mac places it without motion while the Space slides and the surface is hidden;
        // here a window is maximized in plain sight, so the row goes and comes back moving
        // (`scene.setFullscreen`): the shape on the closing spring, the row on its own fade.
        if (this.scene.setFullscreen(fullscreen))
            this._wake();
    }

    /** An alert was activated: open and pinned, on the page it was on, with its window pointed at. */
    openAlert(provider, windowId) {
        this.scene.highlight({provider, windowId});
        this.scene.pin();
        this._takeFocus();
        this._wake();
    }

    /** Open and pinned on the page it is on, with the keyboard (onboarding finished). */
    openPinned() {
        this.scene.pin();
        this._takeFocus();
        this._wake();
    }

    /** The keyboard comes to the pinned surface, and the window that had it is remembered. */
    _takeFocus() {
        const focused = global.display.focus_window;
        if (focused)
            this._returnFocus = focused;
        this.actor.grab_key_focus();
    }

    /** Unpinned: the keyboard goes back where it was, if the surface still has it. */
    _giveFocusBack() {
        const window = this._returnFocus;
        this._returnFocus = null;
        if (global.stage.get_key_focus() !== this.actor)
            return;
        global.stage.set_key_focus(null);
        try {
            if (window && window.get_compositor_private())
                window.activate(global.get_current_time());
        } catch (_e) {
            // The window has gone.
        }
    }

    highlight(window) {
        this.scene.highlight(window);
        this._wake();
    }

    moduleEvent(module, name, data) {
        this.scene.moduleEvent(module, name, data);
        this._wake();
    }

    dismiss() {
        this.scene.dismiss();
        this._wake();
    }

    /**
     * The calendar is open under the bar, or has closed: while it is open the
     * surface lets go and closes, and a pointer resting on the strip does not
     * open it over the calendar.
     */
    holdClosed(held) {
        this._heldClosed = held;
        if (held && this.scene.expanded)
            this.dismiss();
    }

    focusLost() {
        this.controller.focusLost();
        this._wake();
    }

    /** A PNG the hub sent (a cover) as a Cairo surface. Cairo reads PNG from a file, so it passes through one for a moment. */
    _decodeImage(base64) {
        try {
            const dir = GLib.build_filenamev([GLib.get_user_runtime_dir(), 'capa-the-notch']);
            GLib.mkdir_with_parents(dir, 0o700);
            const path = GLib.build_filenamev([dir, `cover-${GLib.get_monotonic_time()}.png`]);
            GLib.file_set_contents(path, GLib.base64_decode(base64));
            const surface = Cairo.ImageSurface.createFromPNG(path);
            Gio.File.new_for_path(path).delete(null);
            return surface;
        } catch (e) {
            console.error(`capa-the-notch: could not read a cover: ${e}`);
            return null;
        }
    }

    // MARK: - Frames

    /**
     * Draws a frame soon, and keeps drawing while anything moves. The springs
     * and fades want every frame (16 ms); Kapa only when she is next due
     * (`KapaSchedule`); a Module at its own beat; a surface at rest draws
     * nothing and costs nothing (`FrameChain`). A frame already due within
     * `keep` ms will do.
     */
    _wake(keep = FRAME_MS) {
        if (this.scene.pinned !== this._wasPinned) {
            this._wasPinned = this.scene.pinned;
            if (!this._wasPinned)
                this._giveFocusBack();
        }
        this._frames.wake(keep);
    }

    /**
     * The screen's own frames, for a motion: a timeline on the surface's frame clock,
     * playing only while a frame is wanted, runs what was asked for at the start of the
     * screen's next frame — before it is laid out and drawn, so what it draws is in that
     * frame, at the moment that frame shows. A timer stands behind it in case the frame
     * never comes (the surface not on a screen), so a motion can never be left waiting.
     */
    _screenFrames() {
        this._frameFn = null;
        this._frameId = 0;
        this._frameBackup = 0;
        this._timeline = new Clutter.Timeline({actor: this.actor, duration: 1000, repeat_count: -1});
        this._timeline.connect('new-frame', () => this._screenFrame());
    }

    _nextFrame(fn) {
        if (!this._timeline || !this.actor.mapped)
            return 0;
        this._clearFrame(this._frameId);
        this._frameFn = fn;
        this._frameId = (this._frameId % 0x7fffffff) + 1;
        if (!this._timeline.is_playing())
            this._timeline.start();
        this._frameBackup = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 4 * FRAME_MS, () => {
            this._frameBackup = 0;
            this._screenFrame();
            return GLib.SOURCE_REMOVE;
        });
        return this._frameId;
    }

    _clearFrame(id) {
        if (!id || id !== this._frameId || !this._frameFn)
            return;
        this._frameFn = null;
        if (this._frameBackup)
            GLib.source_remove(this._frameBackup);
        this._frameBackup = 0;
    }

    _screenFrame() {
        const fn = this._frameFn;
        this._clearFrame(this._frameId);
        fn?.();
        // Nothing more asked of the screen: the timeline stops, and the screen with it.
        if (!this._frameFn && this._timeline?.is_playing())
            this._timeline.stop();
    }

    /**
     * The layers in use over the rectangles of what they draw, on whole points of the
     * surface so their pixels fall on the surface's, in step with its columns
     * (`LAYER_STEP`); never over the top bar, so drawing one again never makes the
     * shell draw the bar again (what it draws is cut where the bar ends). The rest
     * are hidden, and kept for when they are wanted again.
     */
    _placeLayers() {
        const scene = this.scene;
        for (const [key, layer] of this._layers) {
            if (!scene.layers.has(key) && layer.area.visible)
                layer.area.hide();
        }
        for (const [key, {kind}] of scene.layers) {
            const r = scene.layerRect(key, this._cx ?? 0);
            const layer = this._layers.get(key) ?? this._makeLayer(key, kind);
            if (!r) {
                layer.area.hide();
                continue;
            }
            const x = Math.floor((Math.floor(r.x) - LAYER_PAD) / LAYER_STEP) * LAYER_STEP;
            const y = Math.max(Math.floor(r.y) - LAYER_PAD, Math.ceil(scene.geometry.barHeight));
            const w = Math.ceil(r.x + r.w) + LAYER_PAD - x, h = Math.ceil(r.y + r.h) + LAYER_PAD - y;
            const box = layer.box;
            if (box.x !== x || box.y !== y || box.w !== w || box.h !== h) {
                layer.box = {x, y, w, h};
                layer.area.set_position(x, y);
                layer.area.set_size(w, h);
            }
            if (!layer.area.visible)
                layer.area.show();
        }
    }

    /** A layer for `key`, stacked over the surface in the order the scene draws its kind. */
    _makeLayer(key, kind) {
        const area = new St.DrawingArea({reactive: false, visible: false});
        const layer = {area, kind, box: {x: 0, y: 0, w: 0, h: 0}};
        area.connect('repaint', () => {
            this._paintLayer(key);
            this._frames.painted('layer', key);
        });
        const above = [...this._layers.values()].find(l => LAYER_ORDER[l.kind] > LAYER_ORDER[kind]);
        if (above)
            this.actor.insert_child_below(area, above.area);
        else
            this.actor.add_child(area);
        this._layers.set(key, layer);
        return layer;
    }

    /**
     * The actor is the shape's size and its shoulders, plus whatever a Module
     * hangs under it (the Dictation Capsule): `extent()` says how far to the
     * left, right and down. It takes the pointer over less (`_pickRects`).
     */
    _layout() {
        const extent = this.scene.extent();
        const width = extent.left + extent.right;
        const height = extent.bottom;
        this.actor.set_size(width, height);
        this.actor.set_position(Math.round(this._monitor.x + this._monitor.width / 2 - extent.left), this._monitor.y);
        this._width = width;
        this._height = height;
        this._cx = extent.left;
    }

    /**
     * Where the actor takes the pointer: the shape it is moving to (Swift reads
     * `shape.size`), and what a Module hangs under it, in the actor's coordinates.
     */
    _pickRects() {
        const scene = this.scene;
        const cx = this._cx ?? 0;
        const rects = [scene.shapeTargetRect(cx)];
        for (const o of scene.overlays(cx))
            rects.push({x: o.frame.x, y: o.frame.y, w: o.frame.width, h: o.frame.height});
        return rects;
    }

    /**
     * Whatever of the surface's own work holds the compositor long is said in the journal,
     * with where the surface stood: a session that stalls says where (`journalctl --user`).
     */
    _watchSlow() {
        for (const name of ['_paint', '_paintLayer', 'setState', '_press', '_release', '_motion', '_scroll', '_key', '_syncSaid']) {
            const work = this[name];
            if (typeof work !== 'function')
                continue;
            this[name] = (...args) => {
                const start = GLib.get_monotonic_time();
                try {
                    return work.apply(this, args);
                } finally {
                    const ms = (GLib.get_monotonic_time() - start) / 1000;
                    if (ms >= SLOW_MS) {
                        const scene = this.scene;
                        console.warn(`capa-the-notch: slow ${name.replace(/^_/, '')} ${ms.toFixed(0)} ms ` +
                            `(page ${scene.selected}, ${scene.expanded ? 'open' : 'closed'}${scene.pinned ? ', pinned' : ''})`);
                    }
                }
            };
        }
    }

    _paint() {
        const raw = this.actor.get_context();
        try {
            const [width, height] = this.actor.get_surface_size();
            this.scene.draw(new Gfx(new CairoGjs(raw, Cairo), this._text), {width, height, cx: this._cx});
        } finally {
            raw.$dispose();
        }
    }

    /** What one layer holds, alone, where the surface would have drawn it (`scene.drawLayer`). */
    _paintLayer(key) {
        const layer = this._layers.get(key);
        const raw = layer.area.get_context();
        try {
            const g = new Gfx(new CairoGjs(raw, Cairo), this._text);
            g.translate(-layer.box.x, -layer.box.y);
            this.scene.drawLayer(key, g, this._cx);
        } finally {
            raw.$dispose();
        }
    }

    // MARK: - What a screen reader finds

    /**
     * After a whole drawing, once the paint is over (the actor's children are not
     * changed while it paints): the accessible objects follow what was drawn, and
     * presses elsewhere are listened for while a Module wants them. Nothing here
     * asks for a frame or draws the surface again.
     */
    _queueSaid() {
        if (this._saidIdle)
            return;
        this._saidIdle = GLib.idle_add(GLib.PRIORITY_DEFAULT_IDLE, () => {
            this._saidIdle = 0;
            this._syncSaid();
            this._listenOutside(this.scene.listensOutside());
            return GLib.SOURCE_REMOVE;
        });
    }

    /**
     * One object a node, in drawing order, each told only what changed; the ones left
     * over hidden, not destroyed. The strip is the actor itself, which keeps its own
     * name and has what its two sides say as its description.
     */
    _syncSaid() {
        let n = 0;
        for (const node of this.scene.accessibleNodes()) {
            if (node.id === 'strip') {
                if (node.description !== this._description) {
                    this._description = node.description;
                    this.actor.get_accessible()?.set_description(node.description);
                }
                // The toggle is on while the surface is open: "pressed", as a screen reader says it.
                const open = this.scene.expanded;
                if (open !== this._saidOpen) {
                    this._saidOpen = open;
                    if (open)
                        this.actor.add_accessible_state(Atk.StateType.CHECKED);
                    else
                        this.actor.remove_accessible_state(Atk.StateType.CHECKED);
                }
                continue;
            }
            let widget = this._said[n];
            if (!widget) {
                widget = new AccessibleNode();
                this._said.push(widget);
                this.actor.add_child(widget);
            }
            this._tell(widget, node);
            n++;
        }
        for (let i = n; i < this._said.length; i++) {
            const widget = this._said[i];
            if (widget.said.focused) {
                widget.remove_accessible_state(Atk.StateType.FOCUSED);
                widget.said = {...widget.said, focused: false};
            }
            if (widget.visible)
                widget.hide();
        }
    }

    _tell(widget, node) {
        const was = widget.said;
        const x = Math.floor(node.x), y = Math.floor(node.y);
        const w = Math.max(Math.ceil(node.x + node.w) - x, 1), h = Math.max(Math.ceil(node.y + node.h) - y, 1);
        if (was.x !== x || was.y !== y)
            widget.set_position(x, y);
        if (was.w !== w || was.h !== h)
            widget.set_size(w, h);
        if (was.label !== node.label)
            widget.accessible_name = node.label;
        if (was.role !== node.role) {
            widget.accessible_role = ROLES[node.role] ?? Atk.Role.PUSH_BUTTON;
            // A control is there to be used, though the object over it takes no pointer (the
            // surface does): without these a screen reader calls every button unavailable.
            for (const state of [Atk.StateType.ENABLED, Atk.StateType.SENSITIVE]) {
                if (node.role === 'label')
                    widget.remove_accessible_state(state);
                else
                    widget.add_accessible_state(state);
            }
        }
        if (was.selected !== node.selected) {
            if (node.selected)
                widget.add_accessible_state(Atk.StateType.SELECTED);
            else
                widget.remove_accessible_state(Atk.StateType.SELECTED);
        }
        if (was.description !== node.description)
            widget.get_accessible()?.set_description(node.description);
        if (!widget.visible)
            widget.show();
        // The control the keyboard is on (Tab, Shift-Tab): focused, which a screen reader announces.
        if (was.focused !== node.focused) {
            if (node.focused)
                widget.add_accessible_state(Atk.StateType.FOCUSED);
            else
                widget.remove_accessible_state(Atk.StateType.FOCUSED);
        }
        widget.said = {
            x, y, w, h, label: node.label, role: node.role, selected: node.selected, description: node.description, focused: node.focused,
        };
    }

    /**
     * Presses anywhere, while a Module wants them: one that lands off the surface is
     * `pressOutside`. Heard on their way down, and never taken from where they go.
     */
    _listenOutside(on) {
        if (on === !!this._outsideId)
            return;
        if (!on) {
            global.stage.disconnect(this._outsideId);
            this._outsideId = 0;
            return;
        }
        this._outsideId = global.stage.connect('captured-event', (_stage, event) => {
            const type = event.type();
            if (type !== Clutter.EventType.BUTTON_PRESS && type !== Clutter.EventType.TOUCH_BEGIN)
                return Clutter.EVENT_PROPAGATE;
            const target = global.stage.get_event_actor(event);
            if (!target || !this.actor.contains(target)) {
                if (this.scene.pressOutside())
                    this._wake();
            }
            return Clutter.EVENT_PROPAGATE;
        });
    }

    // MARK: - Input

    _local(event) {
        const [x, y] = event.get_coords();
        return {x: x - this.actor.x, y: y - this.actor.y};
    }

    _press(event) {
        const p = this._local(event);
        // The other buttons mean nothing to the surface, as on the Mac.
        if (event.get_button() === 1 && this.scene.press(p.x, p.y)) {
            this._wake();
            return Clutter.EVENT_STOP;
        }
        return Clutter.EVENT_PROPAGATE;
    }

    /**
     * The button went up: a button pressed acts if the pointer is still on it, a
     * drag (the Script's progress) ends where it was. The pointer leaving
     * (`event` null) lets a pressed button go without acting.
     */
    _release(event) {
        const p = event ? this._local(event) : null;
        if (this.scene.release(p?.x, p?.y, {cancel: !event}))
            this._wake();
        return Clutter.EVENT_PROPAGATE;
    }

    _motion(event) {
        const p = this._local(event);
        this.scene.setPointer(this.scene.expanded ? p : null);
        // What the pointer changes (a button lit, a tile, Kapa's eyes) wakes the frames
        // itself (`scene.onChange`); a pointer crossing what does not answer to it draws nothing.
        if (!this.controller._fileDrop)
            this.scene.setShapePointer(p);
        return Clutter.EVENT_PROPAGATE;
    }

    /** Whether scrolling is "natural" on the touchpad: the content follows the fingers. */
    get _natural() {
        try {
            return this._touchpad?.get_boolean('natural-scroll') ?? true;
        } catch (_e) {
            return true;
        }
    }

    /**
     * Two fingers on the touchpad (`follow(swipe:)`, `moveScript(with:)`): the
     * first event of a gesture begins a swipe, the fingers lifting end it. Mouse
     * wheels are not swipes. Directions are the fingers', whichever way the
     * person has scrolling set: fingers moving left bring the next page in.
     */
    _scroll(event) {
        if (event.get_scroll_direction() !== Clutter.ScrollDirection.SMOOTH
            || event.get_scroll_source() !== Clutter.ScrollSource.FINGER)
            return Clutter.EVENT_PROPAGATE;
        const [rawX, rawY] = event.get_scroll_delta();
        // Mutter turns the deltas round for natural scrolling; turned back, they are
        // where the fingers went (right and down positive).
        const sign = this._natural ? -1 : 1;
        const dx = sign * rawX * FINGER_POINTS, dy = sign * rawY * FINGER_POINTS;
        const finish = event.get_scroll_finish_flags?.() ?? 0;
        const lifted = (finish & (Clutter.ScrollFinishFlags.HORIZONTAL | Clutter.ScrollFinishFlags.VERTICAL)) !== 0;

        // Two fingers up the closed surface's row: a Module's row (the Script) follows them.
        // Only under the strip, inside the shape.
        if (!this.scene.expanded && !this._swiping && Math.abs(dy) >= Math.abs(dx) && !lifted) {
            const p = this._local(event);
            const shape = this.scene.shapeTargetRect(this._cx ?? 0);
            const overRow = p.x >= shape.x && p.x < shape.x + shape.w
                && p.y > this.scene.geometry.barHeight && p.y < shape.h;
            // The content goes the way the fingers do: up, reading further.
            if (overRow && this.scene.scrollCompactRow(-dy)) {
                this._wake();
                return Clutter.EVENT_STOP;
            }
        }

        const controller = this.controller;
        if (!this._swiping) {
            if (lifted || !(Math.abs(dx) > Math.abs(dy)))
                return Clutter.EVENT_PROPAGATE;
            if (!controller.swipe('began'))
                return Clutter.EVENT_PROPAGATE;
            this._swiping = true;
        }
        const ended = () => {
            this._clearSwipeQuiet();
            if (!this._swiping)
                return;
            this._swiping = false;
            controller.swipe('ended');
            this._wake();
        };
        if (dx !== 0)
            controller.swipe('changed', dx);
        if (lifted) {
            ended();
        } else {
            // The lift can be lost: silence ends the gesture where it is.
            this._clearSwipeQuiet();
            this._swipeQuiet = GLib.timeout_add(GLib.PRIORITY_DEFAULT, SWIPE_QUIET_MS, () => {
                this._swipeQuiet = 0;
                ended();
                return GLib.SOURCE_REMOVE;
            });
        }
        this._wake();
        return Clutter.EVENT_STOP;
    }

    _clearSwipeQuiet() {
        if (this._swipeQuiet)
            GLib.source_remove(this._swipeQuiet);
        this._swipeQuiet = 0;
    }

    _key(event) {
        const names = {
            [Clutter.KEY_Escape]: 'Escape', [Clutter.KEY_Left]: 'ArrowLeft', [Clutter.KEY_Right]: 'ArrowRight',
            [Clutter.KEY_Tab]: 'Tab', [Clutter.KEY_ISO_Left_Tab]: 'ShiftTab',
            [Clutter.KEY_space]: 'Space', [Clutter.KEY_Return]: 'Enter', [Clutter.KEY_KP_Enter]: 'Enter',
        };
        const name = names[event.get_key_symbol()];
        if (name && this.controller.key(name)) {
            this._wake();
            return Clutter.EVENT_STOP;
        }
        return Clutter.EVENT_PROPAGATE;
    }

    destroy({fromActor = false} = {}) {
        // Once: the extension's disable, or the Shell tearing its actors down as it quits
        // (when nothing of the surface may touch the panel or the display any more).
        if (this._destroyed)
            return;
        this._destroyed = true;
        this._frames.destroy();
        this._clearFrame(this._frameId);
        this._timeline.stop();
        this._timeline = null;
        if (this._saidIdle)
            GLib.source_remove(this._saidIdle);
        this._saidIdle = 0;
        this._listenOutside(false);
        this._said = [];
        this._text.destroy();
        if (this._beat)
            GLib.source_remove(this._beat);
        this._beat = 0;
        this._clearSwipeQuiet();
        if (this._focusWindowId)
            global.display.disconnect(this._focusWindowId);
        if (this._workAreasId)
            global.display.disconnect(this._workAreasId);
        this._focusWindowId = this._workAreasId = 0;
        this._touchpad = null;
        this._returnFocus = null;
        if (this._clockTimer)
            GLib.source_remove(this._clockTimer);
        this._clockTimer = 0;
        if (this._clockFormat)
            this._interface?.disconnect(this._clockFormat);
        if (this._animationsId)
            this._interface?.disconnect(this._animationsId);
        if (this._schemeId)
            this._interface?.disconnect(this._schemeId);
        this._interface = null;
        for (const id of this._events)
            this.actor.disconnect(id);
        this._layers.clear();
        if (!fromActor)
            this.actor.destroy();
    }
}
