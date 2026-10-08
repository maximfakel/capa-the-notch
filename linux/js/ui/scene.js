// The Notch Surface as one scene: the black shape and its motion, the strip,
// the pages, the page switcher. `NotchRootView`, `SurfaceColumn`,
// `CompactCapacityView` and `PageSwitcher` in Swift. A surface gives it a
// Cairo-style context and a clock and tells it where the pointer is; it draws
// itself and says what was hit.
//
// Coordinates are the window's, from its top left, with the surface centred
// on `viewport.width / 2` and hanging from the top edge.
//
// What the scene reads (`model`, all of it already decided by the hub):
//   providers   ProviderView[] for every Provider, in order (see view.rs)
//   strip       {left, right}: each null or {provider, figure, pace}
//   pages       the page ids there are, in order: 'capacity', 'music', ...
//   language    'en' | 'ru'
// and what it asks of the surface (`actions`): refresh(provider),
// connect(provider), openSettings(section), togglePin(), openCalendar().

import {addOutline} from '../geometry.js';
import {drawMark} from '../marks.js';
import {Fade, Spring, ease} from './springs.js';
import {Colors, Metrics, Type} from './metrics.js';
import {drawIcon} from './icons.js';
import {PRESSED_OPACITY, paceDot} from './widgets.js';
import {drawCapacityPage} from './pages/capacity.js';
import {KapaEngine, capacityFocus, drawKapa} from './kapa/index.js';
import {MODULES} from './modules/index.js';
import {t} from './strings.js';
import {sameValue} from './model.js';

const PACE = {sustainable: Colors.green, tightening: Colors.yellow, unsustainable: Colors.red};

/** Kapa's hello is said once a launch (`KapaView.greeted`). */
let greeted = false;

/** `SettingsPalette.accent`: the ring of keyboard focus. */
const ACCENT = [0x6B / 255, 0x97 / 255, 1];

/** Whether two rectangles `{x, y, w, h}` are the same one. */
const sameRect = (a, b) => !!a && !!b && a.x === b.x && a.y === b.y && a.w === b.w && a.h === b.h;

const PAGE_ICON = {capacity: 'providers', music: 'music', teleprompter: 'teleprompter', shelf: 'shelf'};
const PAGE_NAME = {capacity: 'Capacity', music: 'Music', teleprompter: 'Teleprompter', shelf: 'Shelf'};

export class SurfaceScene {
    /**
     * @param {{barHeight: number, notchWidth: number}} geometry the strip's height and the notch's width (0 without one)
     * @param {object} actions what the surface does when something is pressed
     */
    constructor(geometry, actions) {
        this.geometry = geometry;
        this.actions = actions;
        this.model = {providers: [], strip: {left: null, right: null}, pages: ['capacity'], language: 'en'};
        this.pageDrawers = {capacity: drawCapacityPage};
        for (const m of MODULES) {
            if (m.page)
                this.pageDrawers[m.page] = (g, scene, box, ctx) => m.drawPage(g, scene, box, ctx);
        }

        this.presentation = 'compact';
        this.pinned = false;
        this.selected = 'capacity';
        this.highlighted = null;
        this.controlsShown = false;
        this.pointerNear = false;
        this.travel = 0; // a swipe under way, in points; negative towards the next page
        /** The page buttons' own motion, by page: how lit and how pressed each is (`PageIndicator`). */
        this.switcher = new Map();
        /**
         * The control the keyboard is on (`@FocusState`, `.focusable()`): a hit's id, among
         * those that say `focusable` — the cards' buttons, and the page buttons while they show.
         */
        this.focused = null;

        const open = this.openWidth;
        const compact = this.compactWidth;
        this.width = new Spring(compact, 0.45, 1.0);
        this.height = new Spring(geometry.barHeight, 0.45, 1.0);
        this.radius = new Spring(Metrics.compactRadius, 0.45, 1.0);
        // The springs that are shares of something wider settle as near as the
        // points do: a page is 560 of them, the strip's widening 190, the switcher's growth 14.
        // A page comes to rest less than a tenth of a point from where it stops.
        this.stripWide = new Spring(0, 0.45, 1.0, {epsilon: 0.001});
        this.controls = new Spring(0, 0.38, 0.86, {epsilon: 0.002});
        this.pagePosition = new Spring(0, 0.42, 0.8, {epsilon: 0.0001});
        /** The open content's fade, and the closed row's: two, each on its own curve (`contentMotion`). */
        this.content = new Fade(0);
        this.rowFade = new Fade(1);
        /**
         * The closed row's share while a window covering the screen comes or goes (`setFullscreen`):
         * the music row leaves on the row's own fade, and comes back on it, as the shape moves.
         * `_coverRow` is the id of the Module whose row it fades, null while none does.
         */
        this.coverFade = new Fade(1);
        this._coverRow = null;
        this._springs = [this.width, this.height, this.radius, this.stripWide, this.controls, this.pagePosition];
        this._open = open;

        this.hits = [];
        /**
         * What a screen reader is told of the last drawing, in the order it was drawn: every
         * hit with a label, and the labels that answer to nothing (`addLabel`: a card, a gauge,
         * a side of the strip). The host stands its accessible objects over them.
         */
        this.nodes = [];
        /** What a Module keeps between frames (scroll positions, a spring), by Module id. */
        this.moduleUi = {};
        /** The host's picture loader: `get(path) -> handle | null`, calling `scene.onChange()` when one arrives. */
        this.images = {get: () => null};
        /** The row a swipe scrolls instead of turning the page, while one overflows (the Shelf's). */
        this.scrollableRow = null;
        /** The button the pointer went down on: a Button acts on the release, if the pointer is still on it. */
        this._pressed = null;
        this._pressInside = false;
        /** How many frames have been drawn: a Kapa not drawn in the last one is coming back. */
        this._drawCount = 0;
        this.engines = new Map();
        this.kapaDue = Infinity;
        /**
         * A host that can draw parts of the surface on layers of their own says so here
         * (`liveLayers`), and is told before each drawing of the whole which go on them
         * (`layers`, from `planLayers()`): the closed row's moving part (the music bars,
         * or Kapa; the Script's lines), a Kapa on the open page, and what a Module hangs
         * under the shape (the Dictation capsule). Then only those small layers are
         * drawn again while nothing else moves, each at the moment it asks for (its
         * `due`), and the surface itself is left as it is.
         */
        this.liveLayers = false;
        /** The layers in use, by key: `{kind, due}`, and what the kind needs. */
        this.layers = new Map();
        /** The layer being drawn (`drawLayer`), by its key; null while it is the surface. */
        this._onLayer = null;
        /** How many times each layer has been drawn, as `_drawCount` counts the surface's. */
        this._layerCounts = new Map();
        /** The drawing of the surface by which a layer was no longer in use, by key. */
        this._layersGone = new Map();
        /**
         * Where each Kapa on the open page stood, with her room, in the last drawing made at
         * rest (`_pageRoom`), by layer key and from the surface's middle: where her layer goes.
         */
        this._rooms = new Map();
        /** Whether `_rooms` is from a drawing made at rest; `_roomsNow` the drawing's own, while it is made. */
        this._roomsSettled = false;
        this._roomsNow = null;
        /** The page being drawn, while a Kapa on it may go on a layer: what of it she may take. */
        this._pageClip = null;
        this._cx = 0;
        this.pointer = null;
        this.shapePointer = null;
        this.dragPoint = null;
        this.hoverId = null;
        /**
         * The rectangles the last drawing asked about the pointer (`pointerIn`), and
         * what it was told: the pointer moving changes the picture only where one of
         * them would now be answered otherwise.
         */
        this._pointerAsked = [];
        this._drawing = false;
        this.now = 0;
        this._lastNow = null;
        /**
         * When the first motion since the surface came to rest was asked for (seconds, on
         * the host's clock): the first frame after the pause is that far into it, as
         * SwiftUI's first frame of an animation is as far in as the moment it shows.
         */
        this._restartAt = null;
        /**
         * The host's clock, in seconds on the clock `tick` is given, or null to use the
         * last tick's. A fade begun between frames starts when it was asked for, not
         * at a tick that may be long gone.
         */
        this.time = null;
        this.onChange = () => {};
        /** Told, with its key, when a change is only what one layer draws (`setModel`); null to have `onChange` told of every change. */
        this.onLayerChange = null;
        /** Told when the surface opens or closes, so the hub can read Providers at the pace it sets. */
        this.onPresentation = () => {};
    }

    get openWidth() {
        const g = this.geometry;
        return Math.max(g.notchWidth + 170 * 2, Metrics.minimumSurfaceWidth);
    }

    /** 370 over a 185-point notch at default scaling, 410 over a 220-point one; the narrower without. */
    get compactWidth() {
        const g = this.geometry;
        const drawn = g.notchWidth > 200 ? 410 : 370;
        return Math.min(Math.max(drawn, g.notchWidth + 185), this.openWidth);
    }

    get expanded() {
        return this.presentation === 'expanded';
    }

    /** Whether a model (`setModel`) would change anything of the one the scene has. */
    differs(model) {
        for (const key of Object.keys(model)) {
            if (!sameValue(model[key], this.model?.[key]))
                return true;
        }
        return false;
    }

    setModel(model) {
        // A change only one layer shows (the voice's level, while the capsule is on its
        // layer) draws that layer again, and leaves the surface as it is.
        const layer = this._layerOnly(model);
        this.model = {...this.model, ...model};
        if (layer !== null) {
            this.observeModules();
            this.onLayerChange(layer);
            return;
        }
        const pages = this.model.pages;
        if (!pages.includes(this.selected))
            this.selected = 'capacity';
        // The strip's own width and where the pages stand change at once, as they do in
        // Swift; a row arriving or leaving under the closed strip changes the shape's
        // size, and the shape moves to it on the closing spring (`positionPanel(animated: true)`).
        const wide = this.expanded || this.compactRow()?.wide ? 1 : 0;
        if (this.stripWide.target !== wide)
            this.stripWide.set(wide);
        const index = Math.max(pages.indexOf(this.selected), 0);
        if (this.travel === 0 && this.pagePosition.target !== index)
            this.pagePosition.shift(index);
        // The first state is where the surface starts, not somewhere it moves to.
        this.retarget(this._modelSeen === true);
        this._modelSeen = true;
        this.observeModules();
        this.onChange();
    }

    /**
     * The layer in use that is all a change of the model would change, or null: a
     * Module's state, changed only where its part on a layer draws (`layerOnly`).
     */
    _layerOnly(model) {
        if (!this.onLayerChange)
            return null;
        let layer = null;
        for (const key of Object.keys(model)) {
            if (sameValue(model[key], this.model?.[key]))
                continue;
            if (key !== 'modules')
                return null;
            const before = this.model.modules ?? {}, after = model.modules ?? {};
            for (const id of new Set([...Object.keys(before), ...Object.keys(after)])) {
                if (sameValue(before[id], after[id]))
                    continue;
                const m = MODULES.find(x => x.id === id);
                const which = `overlay:${id}`;
                if (layer !== null || !this.layers.has(which) || !m?.layerOnly?.(before[id], after[id]))
                    return null;
                layer = which;
            }
        }
        return layer;
    }

    /** Each Module sees the state and the page as they stand (the Shelf notices files arriving, its page coming into view). */
    observeModules() {
        const model = this.pageModel();
        for (const m of MODULES)
            m.observe?.(this, {...model, module: this.model.modules?.[m.id]});
    }

    setGeometry(geometry) {
        this.geometry = geometry;
        this.retarget(false);
    }

    /**
     * A window covering the screen came or went (a fullscreen application, or one opened to
     * the whole screen): the closed surface is the strip alone over it. The Mac moves the shape
     * while the surface is hidden by the Space sliding; here it happens in plain sight, so the
     * shape moves on the closing spring, as for a row arriving or leaving (`setModel`), and
     * the music row fades on the closed row's own curve (`_fadeContent`) rather than jumping.
     * Open, nothing of the row shows, and it simply is or is not there when the surface closes.
     */
    setFullscreen(on) {
        on = !!on;
        if (!!this.fullscreen === on)
            return false;
        const before = this.compactRow()?.module.id ?? null;
        this.fullscreen = on;
        const after = this.compactRow()?.module.id ?? null;
        if (this.expanded || before === after) {
            this._coverRow = null;
            this.coverFade = new Fade(1);
        } else if (after === null) {
            // Leaving: the row as it was is drawn on, fading, until it is gone.
            this._coverRow = before;
            this._rowMotion(this.coverFade, false);
        } else {
            // Coming back, from where a leaving fade had got to, or from nothing.
            if (this._coverRow !== after)
                this.coverFade = new Fade(0);
            this._coverRow = after;
            this._rowMotion(this.coverFade, true);
        }
        this.retarget(true);
        return true;
    }

    /**
     * The closed row as it is drawn now, and its share: the row there is, or, while it fades
     * out from under a covering window, the one that was (`setFullscreen`). `leaving` is true
     * for that one, which is shown and no longer pressed or heard.
     */
    shownRow() {
        const row = this.compactRow();
        const covered = this._coverRow;
        if (covered === null)
            return row ? {row, share: this.rowFade.value, leaving: false} : null;
        if (row)
            return {row, share: this.rowFade.value * (row.module.id === covered ? this.coverFade.value : 1), leaving: false};
        const was = this.compactRow({fullscreen: false});
        return was?.module.id === covered ? {row: was, share: this.rowFade.value * this.coverFade.value, leaving: true} : null;
    }

    // MARK: - State changes (the store's and the pages')

    expand() {
        if (this.expanded)
            return;
        this.presentation = 'expanded';
        this.retarget(true);
        this._fadeContent(true);
        this.onPresentation(true);
    }

    collapse() {
        if (!this.expanded)
            return;
        this.presentation = 'compact';
        // The buttons go back to dots with the surface, and the keyboard leaves them.
        this.controlsShown = false;
        this.focused = null;
        if (this.controls.target !== 0) {
            if (this.reduced)
                this.controls.tween(0, 0.18, null, this._lead());
            else
                this.controls.to(0, 0.38, 0.86, this._lead());
        }
        this.retarget(true);
        this._fadeContent(false);
        this.onPresentation(false);
    }

    pin() {
        this.pinned = true;
        this.expand();
    }

    dismiss() {
        this.pinned = false;
        this.collapse();
    }

    togglePin() {
        this.pinned ? this.dismiss() : this.pin();
    }

    /** A page's own button (`SurfacePages.select`): another page, never the one shown. */
    select(page) {
        if (!this.model.pages.includes(page) || page === this.selected)
            return;
        this._turn(page);
    }

    step(by) {
        const pages = this.model.pages;
        const i = Math.max(pages.indexOf(this.selected), 0);
        const page = pages[Math.min(Math.max(i + by, 0), pages.length - 1)];
        if (page)
            this._turn(page);
    }

    /**
     * Turns to `page`, or back to it after a swipe that fell short (`SurfacePages.turn`):
     * the pages move on the opening spring from wherever the fingers left them, so
     * the window's height and the pages arrive together. A turn under way is taken
     * over at the speed it had (`withAnimation` merging springs); one from a swipe
     * starts still, as the fingers carry no speed into it. The dots change on the same
     * spring: the page's own goes bright as the others go faint (`PageIndicator.fill`).
     * Nothing changing, nothing moves: the arrows at either end.
     */
    _turn(page) {
        if (page === this.selected && this.travel === 0)
            return;
        // Each dot as it stands before the turn, for the turn to change.
        for (const id of this.model.pages)
            this.switcherState(id);
        this.selected = page;
        this.travel = 0;
        const index = this.model.pages.indexOf(page);
        const lead = this._lead();
        const move = (spring, target) => {
            if (this.reduced)
                spring.tween(target, 0.15, null, lead);
            else
                spring.to(target, 0.42, 0.8, lead);
        };
        move(this.pagePosition, index);
        for (const id of this.model.pages)
            move(this.switcherState(id).current, id === page ? 1 : 0);
        this.onChange();
    }

    /**
     * How long after the last frame a motion asked for now begins (seconds), for the
     * springs and curves to start then (`Spring.to`). The first motion after a rest is
     * where the next frame counts from (`tick`).
     */
    _lead() {
        const at = this.clockNow();
        const from = this._lastNow ?? this._restartAt;
        if (from == null) {
            this._restartAt = at;
            return 0;
        }
        return Math.max(at - from, 0);
    }

    /**
     * A swipe under way: how far the fingers have carried the pages. They follow at
     * once, and beyond either end only a third as far, so the edge gives a little and
     * then holds (`stripPosition`).
     */
    follow(travel) {
        // Under Reduce Motion the pages stay put until the swipe ends, then change without travelling.
        if (this.reduced)
            return;
        if (travel === this.travel)
            return;
        this.travel = travel;
        const last = Math.max(this.model.pages.length - 1, 0);
        const moved = Math.max(this.model.pages.indexOf(this.selected), 0) - travel / this.openWidth;
        // Without animation: a turn still under way finishes over where the fingers have them.
        this.pagePosition.shift(moved < 0 ? moved / 3 : moved > last ? last + (moved - last) / 3 : moved);
        this.onChange();
    }

    /** Ends a swipe: past forty points it turns the page, short of that the pages settle back. */
    settle(travel) {
        const steps = travel < -Metrics.swipeTurn ? 1 : travel > Metrics.swipeTurn ? -1 : 0;
        this.step(steps);
    }

    setControlsShown(shown) {
        if (shown === this.controlsShown)
            return;
        this.controlsShown = shown;
        if (!shown && this.focused?.startsWith('page:'))
            this.focused = null;
        if (this.reduced)
            this.controls.tween(shown ? 1 : 0, 0.18, null, this._lead());
        else
            this.controls.to(shown ? 1 : 0, 0.38, 0.86, this._lead());
        this.retarget(true, {response: 0.38, damping: 0.86, duration: 0.18});
    }

    setPointerNear(near) {
        if (near === this.pointerNear)
            return;
        this.pointerNear = near;
        this.retarget(true, {response: 0.28, damping: 0.7});
    }

    highlight(window) {
        this.highlighted = window;
    }

    // MARK: - Targets

    /** The height of the open surface: every page has the same room, and the switcher adds to it. */
    get openHeight() {
        const growth = this.controlsShown ? Metrics.switcherGrowth : 0;
        // Never taller than the room the screen has for it (`screen.visibleFrame`).
        return Math.min(this.geometry.barHeight + Metrics.pageHeight + Metrics.switcherHeight + growth,
            this.geometry.maxHeight ?? Infinity);
    }

    /** The row a Module has under the closed strip, if one: the highest priority of those that have. */
    compactRow(extra = null) {
        const ctx = extra ? {...this.pageModel(), ...extra} : this.pageModel();
        let best = null;
        for (const m of MODULES) {
            const row = m.compactRow?.({...ctx, module: this.model.modules?.[m.id]});
            if (row && (!best || row.priority > best.priority))
                best = {...row, module: m};
        }
        return best;
    }

    /**
     * How often the Modules want drawing, in seconds: 0 every frame (a playing track),
     * a beat a Module names with `needsFrames` returning `{interval}` (the open
     * Teleprompter page, four times a second), Infinity not at all.
     */
    moduleFrameInterval() {
        const ctx = this.pageModel();
        let interval = Infinity;
        for (const m of MODULES) {
            const wants = m.needsFrames?.({...ctx, module: this.model.modules?.[m.id]});
            if (!wants)
                continue;
            interval = Math.min(interval, typeof wants === 'object' && wants.interval > 0 ? wants.interval : 0);
        }
        return interval;
    }

    /** A Module that keeps moving (a running Script, a playing track) keeps the frames coming. */
    modulesNeedFrames() {
        return this.moduleFrameInterval() === 0;
    }

    /**
     * Seconds until something wants drawing again though nothing moves: a Module's
     * beat, and, open on Capacity, the reset times on the half-minute (the
     * `TimelineView` the Swift page sits in). Infinity when nothing does.
     */
    timedRedrawDelay(wallMs = Date.now()) {
        let delay = this.moduleFrameInterval();
        if (this.expanded && this.selected === 'capacity')
            delay = Math.min(delay, 30 - (wallMs / 1000) % 30);
        return delay;
    }

    /** Something a Module said that is not state (the hub's `ModuleEvent`). */
    moduleEvent(module, name, data) {
        MODULES.find(m => m.id === module)?.onEvent?.(this, name, data);
        this.onChange();
    }

    /**
     * Whether the surface is kept out of screen recordings: unless sharing was allowed — and
     * whatever that says, while a Module holds something that must not be shared (the
     * Shelf's Clippings, a running Script) (`applySharing`, `TeleprompterSurface.excludedFromCapture`).
     */
    excludedFromCapture() {
        if (!this.model.screenSharingAllowed)
            return true;
        const ctx = this.pageModel();
        return MODULES.some(m => m.excludesFromCapture?.({...ctx, module: this.model.modules?.[m.id]}));
    }

    /** Whether a passing pointer may open the surface (the Teleprompter says no while it runs). */
    hoverOpens() {
        return MODULES.every(m => m.hoverOpens?.({...this.pageModel(), module: this.model.modules?.[m.id]}) !== false);
    }

    /** What the closed surface is: the strip, plus whatever row a Module has under it. */
    get compactSize() {
        let {width, height} = {width: this.compactWidth, height: this.geometry.barHeight};
        const row = this.compactRow();
        if (row) {
            // A wide row (the Teleprompter's) takes the open surface's width.
            width = row.wide ? this.openWidth : (row.width ?? width);
            height += row.height;
        }
        if (this.pointerNear) {
            width += Metrics.nearGrowth.width;
            height += Metrics.nearGrowth.height;
        }
        return {width, height};
    }

    /** Reduce Motion: every move is a short ease in place of a spring (`SurfaceType.surfaceMotion(reduced:)`). */
    get reduced() {
        return this.model.reduceMotion === true;
    }

    /**
     * Moves the shape to what it should be now. Animated, a spring whose target
     * has not changed is left alone, as SwiftUI starts no animation for a value
     * that did not change: the pointer coming near does not take over an opening
     * still on its way. Not animated, everything that changed is there at once, and
     * a move still under way finishes over it, as SwiftUI's do.
     */
    retarget(animated, motion = null) {
        const open = this.expanded;
        const size = open ? {width: this.openWidth, height: this.openHeight} : this.compactSize;
        const r = motion ?? (open ? {response: 0.42, damping: 0.8} : {response: 0.45, damping: 1.0});
        const radius = open ? Metrics.openRadius : Metrics.compactRadius;
        const reduced = this.reduced;
        const lead = animated ? this._lead() : 0;
        const move = (spring, target) => {
            // A move that is already on its way to this does not start over: a state
            // arriving mid-way (a refresh) must not stop the surface where it is.
            if (spring.target === target)
                return;
            if (!animated)
                spring.shift(target);
            else if (reduced)
                spring.tween(target, r.duration ?? 0.15, null, lead);
            else
                spring.to(target, r.response, r.damping, lead);
        };
        move(this.width, size.width);
        move(this.height, size.height);
        move(this.radius, radius);
        move(this.stripWide, open || this.compactRow()?.wide ? 1 : 0);
        // The pages move when they are turned (`_turn`) or followed; here they only jump
        // to a page that changed under them.
        if (!animated && this.travel === 0)
            move(this.pagePosition, Math.max(this.model.pages.indexOf(this.selected), 0));
        this.onChange();
    }

    /** Now on the host's clock, for a fade begun between frames. */
    clockNow() {
        return this.time ? this.time() : this.now;
    }

    /**
     * Opening, the open content arrives a beat behind the shape and the closed row
     * leaves quickly; closing, the other way round (`SurfaceType.contentMotion`).
     */
    _fadeContent(open) {
        this._rowMotion(this.content, open);
        this._rowMotion(this.rowFade, !open);
        this.onChange();
    }

    /**
     * One of the fades between the closed row and the open content (`SurfaceType.contentMotion`):
     * appearing, a beat behind the shape on an ease-out; leaving, quickly on an ease-in; under
     * Reduce Motion both a short ease in and out.
     */
    _rowMotion(fade, appearing) {
        const now = this.clockNow();
        const reduced = this.reduced;
        if (appearing)
            fade.start(1, reduced ? 0.15 : 0.22, reduced ? 0 : 0.06, reduced ? ease.inOut : ease.out, now);
        else
            fade.start(0, reduced ? 0.15 : 0.1, 0, reduced ? ease.inOut : ease.in, now);
    }

    /** Advances every motion to `now` (seconds). Returns whether anything is still moving. */
    tick(now) {
        // After a pause, the first frame is as far into its motion as the time since it was asked for.
        const from = this._lastNow ?? this._restartAt ?? now;
        const dt = now - from;
        this._lastNow = now;
        this._restartAt = null;
        this.now = now;
        let moving = false;
        for (const s of this._springs)
            moving = s.step(dt) || moving;
        moving = this.content.step(now) || moving;
        moving = this.rowFade.step(now) || moving;
        moving = this.coverFade.step(now) || moving;
        // The fade over: a row gone from under a covering window is gone, one come back is simply there.
        if (this._coverRow !== null && this.coverFade.value === this.coverFade._to) {
            this._coverRow = null;
            this.coverFade = new Fade(1);
        }
        for (const state of this.switcher.values())
            moving = state.current.step(dt) || state.lit.step(now) || state.press.step(now) || moving;
        return moving;
    }

    /** Every motion of the surface's own is where it is going: the shape, the fades, the page buttons. */
    get atRest() {
        const still = fade => fade.value === fade._to;
        return this._springs.every(s => s.settled) && still(this.content) && still(this.rowFade)
            && still(this.coverFade) && this._coverRow === null
            && [...this.switcher.values()].every(s => s.current.settled && still(s.lit) && still(s.press));
    }

    /** Nothing is moving: a host may stop its frame loop. Kapa never rests while she is on screen. */
    get idle() {
        return this.atRest && this.kapaDue === Infinity && !this.modulesNeedFrames();
    }

    /**
     * Kapa, drawn with her square's top left at (x, y), `size` wide. One engine
     * for each Kapa on screen, kept by `key`. The caller says whether the place
     * she stands is on screen now (`awake`); `tappable` false takes no boop,
     * `hoverable` false does not follow the pointer. With `drawnAt` she is
     * stepped and drawn at that size and shown scaled to `size`, as SwiftUI's
     * `scaleEffect` shows a `KapaView` (the Shelf's drop Kapa). With `parts`
     * (rectangles) she is drawn only inside them, each a picture of its own
     * (`Gfx.isolated`), so the surface and its layer can each draw a part of her;
     * drawn in parts twice at one moment, she is stepped the first time only.
     * Drawn again in the same frame (the Dictation Kapa, once for her shadow and
     * once for herself), she is drawn as she already stands, not stepped again.
     */
    drawKapaAt(g, key, x, y, size, expression, options = {}) {
        if (this.model.showsKapa === false)
            return;
        // A Kapa on the open page that asks for one (`layer`) goes on a layer of her own
        // while the surface is at rest, drawn in her room as one picture whichever draws her.
        const room = this._pageRoom(g, x, y, size, options);
        if (room) {
            const layerKey = `kapa:${key}`;
            const at = {...room, x: room.x - this._cx};
            this._roomsNow?.set(layerKey, at);
            const layer = this.layers.get(layerKey);
            if (layer && sameRect(layer.room, at)) {
                // Her layer draws her; the surface keeps her tap.
                layer.replay = {key, x: x - this._cx, y, size, expression, options};
                this.kapaHit(key, x, y, size, options);
                return;
            }
            options = {...options, parts: [room]};
        }
        const {
            awake = true, look, showsBadge, outline, swallowedAt, level, tappable = true, hoverable = true, drawnAt, parts,
        } = options;
        const engineSize = drawnAt > 0 ? drawnAt : size;
        let engine = this.engines.get(key);
        const fresh = !engine;
        if (!engine) {
            engine = new KapaEngine();
            this.engines.set(key, engine);
        }
        // Kapa looks at the pointer over it, and at a file carried near (`onContinuousHover`, `KapaDrag`).
        // The point is the engine's, at the size it is stepped at.
        const over = hoverable ? this.shapePointer : null;
        const k = size > 0 ? engineSize / size : 1;
        engine.hover = over && over.x >= x && over.x < x + size && over.y >= y && over.y < y + size
            ? {x: (over.x - x) * k, y: (over.y - y) * k} : null;
        engine.dragPoint = () => this.dragPoint;
        // Awake and allowed to move: a tap boops it, and it says hello once a launch (`allowsHitTesting(running)`).
        // On the row layer the surface, which keeps the hits, has taken the tap already (`kapaHit`).
        const running = awake && !this.reduced;
        if (this._onLayer === null)
            this.kapaHit(key, x, y, size, {awake, tappable});
        if (running && expression === 'hello' && !greeted) {
            greeted = true;
            this.actions.sound?.('kapaHello');
        }
        engine.frame = {x, y, width: size, height: size};
        const inputs = {expression, size: engineSize, look, showsBadge, level, swallowedAt};
        // A Kapa that was not on screen last frame comes back as she is now, not
        // through a blink-swap from whatever she was when she left. The surface and
        // each layer count their own frames; handed from one to the other, she was
        // on screen if the one that had her drew her the last time it drew, and is
        // still showing it: the surface, which has drawn this frame already, the
        // time before; a layer, the last time, and in use until this frame.
        const onLayer = this._onLayer;
        const drawer = engine.onLayer ?? null;
        const count = this._countOf(onLayer);
        // The surface drew its part of her a moment ago, and the layer draws the rest.
        const stepped = !!parts && engine.partsAt === this.now;
        // This frame has drawn her already: she is stepped, and on screen.
        const again = !fresh && drawer === onLayer && engine.drawnInFrame === count && engine.drawnNow === this.now;
        const shown = drawer === onLayer ? engine.drawnInFrame === count - 1
            : drawer === null ? engine.drawnInFrame === this._drawCount - 1
                : engine.drawnInFrame === this._countOf(drawer)
                    && (this.layers.has(drawer) || this._layersGone.get(drawer) === this._drawCount);
        if (!fresh && !shown && !stepped && !again)
            engine.step(this.now, {...inputs, moving: false});
        engine.drawnInFrame = count;
        engine.drawnNow = this.now;
        engine.onLayer = onLayer;
        // Kapa sets her own colours, so a fade in force reaches her as one picture laid down fainter.
        const draw = again => g.flattened(() => {
            g.save();
            g.translate(x, y);
            drawKapa(g.cr, g, {
                ...inputs, drawnAt: size, t: this.now, awake, engine, isAnimated: !this.reduced, outline, stepped: again,
            });
            g.restore();
        });
        if (parts) {
            parts.forEach((r, i) => g.isolated(r.x, r.y, r.w, r.h, () => draw(stepped || again || i > 0)));
            engine.partsAt = this.now;
        } else {
            draw(again);
        }
        this.wantFrameAt(engine.nextFrame(this.now));
    }

    /** How many times the surface (`null`) or a layer has been drawn. */
    _countOf(layer) {
        return layer === null ? this._drawCount : this._layerCounts.get(layer) ?? 0;
    }

    /**
     * Kapa's room on the open page, where she may go on a layer: her square, with the
     * room round it she moves and floats her signs in — half her size above, a quarter
     * at the sides and below — kept inside the page, off the margins its edges fade
     * over. Only for a Kapa that asks for it (`layer`), awake, drawn straight onto the
     * surface while the surface is at rest; null otherwise.
     */
    _pageRoom(g, x, y, size, {awake = true, layer = false}) {
        const page = this._pageClip;
        if (!page || !layer || !awake || this._onLayer !== null || !g.plain)
            return null;
        const side = size / 4;
        const x0 = Math.max(x - side, page.x), y0 = Math.max(y - size / 2, page.y);
        const x1 = Math.min(x + size + side, page.x + page.w), y1 = Math.min(y + size + side, page.y + page.h);
        return x1 > x0 && y1 > y0 ? {x: x0, y: y0, w: x1 - x0, h: y1 - y0} : null;
    }

    /** The tap on Kapa's square while she is awake and may move: a boop. */
    kapaHit(key, x, y, size, {awake = true, tappable = true} = {}) {
        if (this.model.showsKapa === false || !awake || this.reduced || !tappable)
            return;
        this.addHit({
            id: `kapa:${key}`, x, y, w: size, h: size, label: '',
            onClick: () => {
                this.engines.get(key)?.boop();
                this.actions.sound?.('kapaTapped');
                this.onChange();
            },
        });
    }

    // MARK: - Pointer and hits

    /**
     * Where the pointer is over the open surface, or null. The surface is drawn
     * again only for what that changes, as SwiftUI redraws on `onHover`: another
     * button under it, a button held or a drag under way, a place the last
     * drawing asked about (`pointerIn`) answered otherwise.
     */
    setPointer(point) {
        this.pointer = point;
        let changed = false;
        if (this._pressed && point) {
            this._pressInside = SurfaceScene._inside(this._pressed, point.x, point.y);
            changed = true;
        }
        if (this.dragging && point) {
            this.dragging.onDrag(point.x, point.y, 'changed');
            changed = true;
        }
        const hover = point ? this.hitAt(point.x, point.y)?.id ?? null : null;
        if (hover !== this.hoverId) {
            this.hoverId = hover;
            changed = true;
        }
        if (this._pointerAsked.some(r => this.pointerIn(r.x, r.y, r.w, r.h) !== r.inside))
            changed = true;
        if (changed)
            this.onChange();
    }

    /**
     * Where the pointer is over the shape, closed or open: what Kapa's eyes follow
     * (`pointer` is the open surface's only). Her coming under it or leaving wakes
     * the surface (`KapaView`'s `nudge`); while it is over her she is moving, and
     * follows it on her own frames.
     */
    setShapePointer(point) {
        const was = this.shapePointer;
        if (point === was || (point && was && point.x === was.x && point.y === was.y))
            return;
        this.shapePointer = point;
        const over = (p, f) => !!p && p.x >= f.x && p.x < f.x + f.width && p.y >= f.y && p.y < f.y + f.height;
        for (const engine of this.engines.values()) {
            const f = engine.frame;
            if (f && over(was, f) !== over(point, f)) {
                this.onChange();
                return;
            }
        }
    }

    /** A file carried near, in the surface's own coordinates, or null (`KapaDrag.shared.point`). */
    setDragPoint(point) {
        const was = this.dragPoint;
        if (point === was || (point && was && point.x === was.x && point.y === was.y))
            return;
        this.dragPoint = point;
        this.onChange();
    }

    isHovered(id) {
        return this.hoverId === id;
    }

    /** Whether the button with this id is held down, the pointer still on it (`configuration.isPressed`). */
    isPressed(id) {
        return !!this._pressed && this._pressed.id === id && this._pressInside;
    }

    static _inside(h, x, y) {
        return x >= h.x && x < h.x + h.w && y >= h.y && y < h.y + h.h;
    }

    /**
     * A region that answers to the pointer. Besides what it does (`onClick`, `onDrag`), it
     * may say what a screen reader calls it (`label`, `description`, `role`: 'button' unless
     * 'tab'; `selected`), and that the keyboard reaches it (`focusable`, its shape's corner
     * `radius`, and `ring`, the rectangle the ring goes round when that is not the region's).
     */
    addHit(region) {
        // The surface keeps every hit: a layer draws, and is never heard or pressed.
        if (this._onLayer !== null)
            return;
        // On a page not chosen (the one beside it, drawn while it may travel in), a
        // control is neither heard nor reached by the keyboard.
        if (this._unheard)
            region.focusable = false;
        this.hits.push(region);
        if (region.label && !this._unheard)
            this.nodes.push(region);
        if (region.focusable && region.id === this.focused && this._gfx) {
            // The ring of keyboard focus: the accent, two points wide, three out from the shape.
            const r = region.ring ?? region;
            this._gfx.strokeRoundRect(r.x - 2, r.y - 2, r.w + 4, r.h + 4, (r.radius ?? 0) + 2, ACCENT, 2);
        }
    }

    /**
     * Words for a screen reader over a rectangle that takes no press and no hover: a
     * card, a gauge, a side of the strip (`accessibilityElement` with its label). Never
     * a hit (`hitAt` does not see it).
     */
    addLabel(node) {
        if (node.label && !this._unheard && this._onLayer === null)
            this.nodes.push({...node, role: 'label'});
    }

    /**
     * What the host's accessible objects stand for: `{id, x, y, w, h, label, description, role, selected, focused}`;
     * `focused` the one the keyboard is on (`focused`), so a screen reader follows Tab as VoiceOver follows `@FocusState`.
     */
    accessibleNodes() {
        return this.nodes.map(n => ({
            id: n.id, x: n.x, y: n.y, w: n.w, h: n.h, label: n.label, description: n.description ?? '',
            role: n.role ?? 'button', selected: !!n.selected, focused: !!n.focusable && n.id === this.focused,
        }));
    }

    /** Whether the pointer is inside this rectangle (`PointerInside`): the open surface only. */
    pointerIn(x, y, w, h) {
        const p = this.pointer;
        const inside = !!p && p.x >= x && p.x < x + w && p.y >= y && p.y < y + h;
        if (this._drawing)
            this._pointerAsked.push({x, y, w, h, inside});
        return inside;
    }

    /** A Module's own motion joins the frame loop. */
    addSpring(spring) {
        this._springs.push(spring);
        return spring;
    }

    /**
     * A frame at `at` (seconds on the scene's clock): the surface's, or a
     * layer's while it is the one being drawn (`drawLayer`).
     */
    wantFrameAt(at) {
        const layer = this._onLayer !== null ? this.layers.get(this._onLayer) : null;
        if (layer)
            layer.due = Math.min(layer.due, at);
        else if (this._onLayer === null)
            this.kapaDue = Math.min(this.kapaDue, at);
    }

    /** Asks for one more frame (a fade in progress). */
    wantFrame() {
        this.kapaDue = Math.min(this.kapaDue, this.now);
    }

    /** The topmost region at a point. Later ones are drawn over earlier ones. */
    hitAt(x, y) {
        for (let i = this.hits.length - 1; i >= 0; i--) {
            const h = this.hits[i];
            if (x >= h.x && x < h.x + h.w && y >= h.y && y < h.y + h.h)
                return h;
        }
        return null;
    }

    /**
     * A press at (x, y). Returns whether a region took it. A button acts on the
     * release, if the pointer is still on it, as a SwiftUI `Button` does (see
     * `release`). A region with `onDrag(x, y, phase)` ('began', 'changed',
     * 'ended') is dragged until `release()`; its action then is the drag.
     */
    press(x, y) {
        // A Module may want to know of any press, wherever it lands (a transient popover).
        let told = false;
        for (const m of MODULES)
            told = m.pressedAnywhere?.(this, x, y) || told;
        if (told)
            this.onChange();
        const hit = this.hitAt(x, y);
        if (hit?.onDrag) {
            this.dragging = hit;
            hit.onDrag(x, y, 'began');
            return true;
        }
        if (!hit?.onClick)
            return false;
        this._pressed = hit;
        this._pressInside = true;
        this.onChange();
        return true;
    }

    /**
     * The button went up at (x, y) (where the pointer last was, if not given): a
     * drag ends there, and a button pressed and still under it acts. `cancel`
     * (the pointer left the surface) lets a pressed button go without acting.
     */
    release(x, y, {cancel = false} = {}) {
        const px = x ?? this.pointer?.x, py = y ?? this.pointer?.y;
        const drag = this.dragging;
        if (drag) {
            this.dragging = null;
            drag.onDrag(px ?? drag.x, py ?? drag.y, 'ended');
            return true;
        }
        const hit = this._pressed;
        if (!hit)
            return false;
        this._pressed = null;
        this._pressInside = false;
        if (!cancel && px != null && py != null && SurfaceScene._inside(hit, px, py))
            hit.onClick();
        this.onChange();
        return true;
    }

    /** A press somewhere that is not the surface at all: a transient popover closes. */
    pressOutside() {
        let told = false;
        for (const m of MODULES)
            told = m.pressedOutside?.(this) || told;
        if (told)
            this.onChange();
        return told;
    }

    /** Whether a Module wants to hear of presses outside the surface now (`pressOutside`). */
    listensOutside() {
        return MODULES.some(m => m.listensOutside?.(this));
    }

    /** A press and a release at one point: a click, as a test or the keyboard makes one. */
    click(x, y) {
        const took = this.press(x, y);
        this.release(x, y);
        return took;
    }

    /**
     * Two fingers moving over the closed surface, `dy` points, positive when the
     * content they hold moves up (reading further). A Module's row may take it.
     */
    scrollCompactRow(dy) {
        const row = this.compactRow();
        return !!row?.module.onScroll?.(this, {...this.pageModel(), module: this.model.modules?.[row.module.id]}, dy);
    }

    /**
     * A scroll gesture over the surface. When the pointer is over a row that
     * overflows (the Shelf's), the row scrolls — all of the gesture, its glide
     * included — and the page stays; returns whether it took it.
     */
    scroll(deltaX) {
        const row = this.scrollableRow;
        if (!row || !this.pointer || !this.pointerIn(row.x, row.y, row.w, row.h))
            return false;
        row.scrollBy?.(deltaX);
        this.onChange();
        return true;
    }

    /** The shape as it stands, centred on `cx`: what is drawn. */
    shapeRect(cx) {
        return {x: cx - this.width.value / 2, y: 0, w: this.width.value, h: this.height.value};
    }

    /**
     * The shape it is moving to, centred on `cx`: what answers to the pointer
     * (`shape.size` in Swift, set at once while the drawing follows on its spring).
     */
    shapeTargetRect(cx) {
        return {x: cx - this.width.target / 2, y: 0, w: this.width.target, h: this.height.target};
    }

    // MARK: - Drawing

    /**
     * @param g the Gfx; @param viewport {width, height} the window's size.
     */
    draw(g, viewport) {
        this._pointerAsked = [];
        this._drawing = true;
        this._gfx = g;
        try {
            this._draw(g, viewport);
        } finally {
            this._drawing = false;
            this._gfx = null;
        }
    }

    _draw(g, viewport) {
        this.observeModules();
        this.hits = [];
        this.nodes = [];
        this.kapaDue = Infinity;
        this._drawCount += 1;
        // The surface hangs from the viewport's `cx` (its middle unless the host says otherwise).
        const cx = viewport.cx ?? viewport.width / 2;
        this._cx = cx;
        // Where the open page's Kapas stand is written down only at rest, where their layers can go.
        this._roomsNow = this.pageLayersReady() ? new Map() : null;
        for (const layer of this.layers.values()) {
            if (layer.kind === 'kapa')
                layer.replay = null;
        }
        const bar = this.geometry.barHeight;
        const w = this.width.value, h = this.height.value;
        const x0 = cx - w / 2;

        // The black shape fills and clips: the column is laid out once, at the
        // open width, and the shape uncovers it.
        g.color(Colors.black);
        g.cr.newPath();
        addOutline(g.cr, x0, 0, w, h, this.radius.value);
        g.cr.fill();

        g.clipped(cr => addOutline(cr, x0, 0, w, h, this.radius.value), () => {
            this.drawStrip(g, cx);
            const column = {x: cx - this.openWidth / 2, y: bar, width: this.openWidth};
            // Both are always there and trade places by fading, each on its own curve,
            // and each answers to the pointer only while it is the one meant
            // (`allowsHitTesting(isExpanded)`, `allowsHitTesting(!isExpanded)`).
            const fade = this.content.value;
            if (fade > 0.002) {
                const mark = this.hits.length, said = this.nodes.length;
                g.group(fade, () => this.drawOpenContent(g, column));
                if (!this.expanded) {
                    this.hits.length = mark;
                    this.nodes.length = said;
                }
            }
            const shown = this.rowFade.value > 0.002 ? this.shownRow() : null;
            const row = shown && shown.share > 0.002 ? shown.row : null;
            if (row) {
                const rowFade = shown.share;
                const mark = this.hits.length, said = this.nodes.length;
                // The row's Kapa is awake while the surface is closed (`kapaAwake: !isExpanded`).
                // On the host's layer, the row's moving part is left out here (`drawLayer`).
                const ctx = {
                    ...this.pageModel(), module: this.model.modules?.[row.module.id], visible: !this.expanded,
                    layer: this.layers.has('row') && !!row.layer,
                };
                g.group(rowFade, () => row.draw(g, this, this._rowBox(row, cx), ctx));
                // A row fading out from under a covering window is no longer pressed or heard.
                if (this.expanded || shown.leaving) {
                    this.hits.length = mark;
                    this.nodes.length = said;
                }
            }
        });

        // What a Module hangs under the shape (the Dictation Capsule): outside the
        // shape's clip, drawn over whatever is there. On the host's layer, its moving
        // part is left to the layer, and the surface keeps only what it answers to.
        for (const overlay of this.overlays(cx)) {
            if (overlay.layer && this.layers.has(`overlay:${overlay.module.id}`)) {
                overlay.layer.hits(this, overlay.ctx);
                continue;
            }
            g.save();
            overlay.draw(g, this, overlay.frame, overlay.ctx);
            g.restore();
        }
        this._rooms = this._roomsNow ?? this._rooms;
        this._roomsSettled = this._roomsNow !== null;
        this._roomsNow = null;
    }

    /**
     * Which parts go on the host's layers for the drawing about to be made, and from
     * then until the next (`layers`): decided before the surface is drawn, so a part
     * is never drawn by both or by neither. Anything that moves — opening, closing,
     * the shape, a fade, a page turning — gives every part back to the surface.
     */
    planLayers() {
        const next = new Map();
        if (this.liveLayers) {
            // The surface may draw a part of the row's Kapa (her notes over the strip): the two are drawn together.
            if (this.rowLayerReady())
                next.set('row', {kind: 'row', shared: true});
            // Where the open page's Kapas stood when it was last drawn at rest: if they
            // stand somewhere else now, the surface draws them, and their layers are empty.
            if (this._roomsSettled && this.pageLayersReady()) {
                for (const [key, room] of this._rooms)
                    next.set(key, {kind: 'kapa', room, replay: null});
            }
            if (this.atRest) {
                for (const o of this.overlays(0)) {
                    if (o.layer)
                        next.set(`overlay:${o.module.id}`, {kind: 'overlay', module: o.module.id});
                }
            }
        }
        // A layer just placed, or placed somewhere else, holds nothing yet: it is drawn with the surface.
        for (const [key, layer] of next) {
            const was = this.layers.get(key);
            layer.due = Infinity;
            layer.fresh = !was || was.kind !== layer.kind || (layer.kind === 'kapa' && !sameRect(was.room, layer.room));
        }
        this._useLayers(next);
        return next;
    }

    _useLayers(next) {
        for (const key of this.layers.keys()) {
            if (!next.has(key))
                this._layersGone.set(key, this._drawCount + 1);
        }
        for (const key of next.keys())
            this._layersGone.delete(key);
        this.layers = next;
    }

    /** Whether the row's moving part is on the host's layer; a host or a test may say so itself. */
    get rowLayer() {
        return this.layers.has('row');
    }

    set rowLayer(on) {
        const next = new Map(this.layers);
        if (on)
            next.set('row', this.layers.get('row') ?? {kind: 'row', due: Infinity});
        else
            next.delete('row');
        this._useLayers(next);
    }

    /** When the row's layer asked to be drawn again (seconds), Infinity for never. */
    get layerDue() {
        return this.layers.get('row')?.due ?? Infinity;
    }

    /**
     * Whether the row's moving part may go on the host's layer now: the surface
     * closed and at rest, the row shown at full strength and with a part of that
     * kind. Anything else — opening, closing, the shape moving, a fade — draws it
     * with the rest, so nothing looks different while it moves.
     */
    rowLayerReady() {
        if (!this.liveLayers || this.expanded || this.fullscreen || !this.atRest || this.rowFade.value < 0.999
            || this.coverFade.value < 0.999)
            return false;
        return !!this.compactRow()?.layer;
    }

    /**
     * Whether a Kapa on the open page may go on a layer: open and at rest, the content
     * shown in full, no page under way and no page's name standing over the page.
     */
    pageLayersReady() {
        return this.liveLayers && this.expanded && this.atRest && this.content.value >= 0.999 && this.travel === 0
            && !this.reduced && [...this.switcher.values()].every(s => s.lit.value < 0.01);
    }

    /** The row's moving part, `{x, y, w, h}` in the scene's coordinates, the surface hanging from `cx`; null when there is none. */
    rowLayerRect(cx) {
        const row = this.compactRow();
        if (!row?.layer)
            return null;
        return row.layer.rect(this._rowBox(row, cx), this._rowContext(row));
    }

    /** Where a layer in use draws, `{x, y, w, h}` in the scene's coordinates, the surface hanging from `cx`; null for none. */
    layerRect(key, cx) {
        const layer = this.layers.get(key);
        switch (layer?.kind) {
        case 'row':
            return this.rowLayerRect(cx);
        case 'kapa':
            return {...layer.room, x: layer.room.x + cx};
        case 'overlay':
            return this.overlays(cx).find(o => o.module.id === layer.module)?.layer?.rect ?? null;
        default:
            return null;
        }
    }

    /**
     * Draws only what the layer `key` holds, as `draw` would have drawn it: the row's
     * moving part in the shape's clip and at the row's fade, a Kapa of the open page
     * in the shape's clip, the moving part of what a Module hangs under the shape.
     * What it asks frames for goes to the layer's `due`; it takes no hits.
     */
    drawLayer(key, g, cx) {
        this._layerCounts.set(key, this._countOf(key) + 1);
        const layer = this.layers.get(key);
        if (!layer)
            return;
        layer.due = Infinity;
        const w = this.width.value, h = this.height.value;
        const shape = cr => addOutline(cr, cx - w / 2, 0, w, h, this.radius.value);
        this._onLayer = key;
        try {
            if (layer.kind === 'row') {
                // As the surface would draw it: a covering window that has just come leaves the
                // row drawn, fading, until the next drawing of the whole takes the layer back.
                const shown = this.rowFade.value > 0.002 ? this.shownRow() : null;
                const row = shown && shown.share > 0.002 ? shown.row : null;
                if (row?.layer) {
                    g.clipped(shape, () => {
                        g.group(shown.share, () => row.layer.draw(g, this, this._rowBox(row, cx), this._rowContext(row)));
                    });
                }
            } else if (layer.kind === 'kapa') {
                // Not drawn by the surface this time: she stood somewhere else, and the surface drew her there.
                const r = layer.replay;
                if (r) {
                    const room = {...layer.room, x: layer.room.x + cx};
                    g.clipped(shape, () => this.drawKapaAt(g, r.key, r.x + cx, r.y, r.size, r.expression, {...r.options, parts: [room]}));
                }
            } else {
                const o = this.overlays(cx).find(o => o.module.id === layer.module);
                if (o?.layer) {
                    g.save();
                    o.layer.draw(g, this, o.frame, o.ctx);
                    g.restore();
                }
            }
        } finally {
            this._onLayer = null;
        }
    }

    /** The row's layer alone (`drawLayer('row')`). */
    drawRowLayer(g, cx) {
        this.drawLayer('row', g, cx);
    }

    _rowBox(row, cx) {
        const width = row.width ?? this.compactWidth;
        return {x: cx - width / 2, y: this.geometry.barHeight, width};
    }

    _rowContext(row) {
        return {...this.pageModel(), module: this.model.modules?.[row.module.id], visible: !this.expanded, layer: true};
    }

    /**
     * The things Modules draw under the shape, in the scene's coordinates:
     * `{module, frame: {x, y, width, height}, draw, ctx}` for each that is showing.
     * `frame` includes the room round it (shadow, popover).
     */
    overlays(cx) {
        const bottom = this.height.value;
        const out = [];
        for (const m of MODULES) {
            if (!m.overlay)
                continue;
            const ctx = {...this.pageModel(), module: this.model.modules?.[m.id]};
            const o = m.overlay(ctx, {cx, bottom, scene: this});
            if (o)
                out.push({module: m, frame: o.frame, draw: o.draw, layer: o.layer ?? null, ctx});
        }
        return out;
    }

    /**
     * What the host must keep drawable: the shape and the shoulders either side,
     * and whatever hangs under it. `left` and `right` are distances from the
     * surface's middle; `bottom` from the top of the screen.
     */
    extent() {
        const half = this.width.value / 2 + Metrics.shoulder + 1;
        let left = half, right = half, bottom = this.height.value + 1;
        for (const o of this.overlays(0)) {
            left = Math.max(left, -o.frame.x);
            right = Math.max(right, o.frame.x + o.frame.width);
            bottom = Math.max(bottom, o.frame.y + o.frame.height);
        }
        return {left: Math.ceil(left), right: Math.ceil(right), bottom: Math.ceil(bottom)};
    }

    /** The time the host shows in the middle of the strip, where a screen without a camera has room; '' for none. */
    setClock(text) {
        if (text === this.clock)
            return;
        this.clock = text;
        this.onChange();
    }

    drawStrip(g, cx) {
        const bar = this.geometry.barHeight;
        const wide = this.stripWide.value;
        const stripW = this.compactWidth + (this.openWidth - this.compactWidth) * wide;
        const inset = Metrics.stripInsetCompact + (Metrics.stripInsetOpen - Metrics.stripInsetCompact) * wide;
        const left = cx - stripW / 2, right = cx + stripW / 2;
        const {strip} = this.model;
        // Numbers drawn under the physical notch are numbers nobody can read;
        // the notch itself is the gap, and no more. The strip is a plain button:
        // held down, both sides dim together.
        g.group(this.isPressed('strip') ? PRESSED_OPACITY : 1, () => {
            if (strip.left)
                this.drawSide(g, strip.left, left + inset, bar, false, 'left');
            if (strip.right)
                this.drawSide(g, strip.right, right - inset, bar, true, 'right');
        });
        let clock = null;
        if (this.clock && !(this.geometry.notchWidth > 0)) {
            const font = Type.compactCapacity;
            const w = g.measureText(this.clock, font);
            g.drawText(this.clock, cx - w / 2, (bar - g.lineHeight(font)) / 2, font, Colors.white);
            clock = {x: cx - w / 2 - 4, w: w + 8};
        }
        this.addHit({
            id: 'strip', x: left, y: 0, w: stripW, h: bar,
            onClick: () => this.actions.togglePin?.(), cursor: 'pointer', label: t('Show or hide Capacity details'),
            // The button's own words stay its own; what each side says is heard after them.
            description: [strip.left?.spoken, strip.right?.spoken].filter(Boolean).join('. '),
        });
        // The time is the desktop's own clock, which the surface covers: a click on
        // it opens what the clock opens (the calendar), and the rest of the strip
        // pins. Closed or opened by the pointer resting on it, as the time shows in both.
        if (clock && this.actions.openCalendar) {
            this.addHit({
                id: 'clock', x: clock.x, y: 0, w: clock.w, h: bar,
                onClick: () => this.actions.openCalendar(), cursor: 'pointer', label: this.clock,
            });
        }
    }

    /** One side of the strip: a Provider's mark, a figure and its pace, heard as one (`CompactSideView`). */
    drawSide(g, side, edge, bar, alignRight, which) {
        const font = Type.compactCapacity;
        const markSize = 15;
        const figureW = g.measureText(side.figure, font);
        const total = markSize + 7 + figureW + (side.pace ? 7 + 6 : 0);
        let x = alignRight ? edge - total : edge;
        g.save();
        g.translate(x, (bar - markSize) / 2);
        drawMark(g.cr, side.provider, markSize, g.alpha);
        g.restore();
        x += markSize + 7;
        g.drawText(side.figure, x, (bar - g.lineHeight(font)) / 2, font, Colors.white);
        x += figureW;
        if (side.pace)
            paceDot(g, x + 7 + 3, bar / 2, PACE[side.pace]);
        this.addLabel({id: `strip:${which}`, x: alignRight ? edge - total : edge, y: 0, w: total, h: bar, label: side.spoken});
    }

    drawOpenContent(g, column) {
        const pages = this.model.pages;
        const bar = this.geometry.barHeight;
        const model = this.pageModel();
        // Only a Shelf drawn this time claims its row and its drop area: one turned
        // away from keeps neither, and a swipe over where it was turns the page.
        this.scrollableRow = null;
        this.shelfDropArea = null;
        // With more than one page they are laid side by side and moved together.
        const position = this.stripPosition();
        pages.forEach((id, i) => {
            const x = column.x + (i - position) * column.width;
            if (x > column.x + column.width || x + column.width < column.x)
                return;
            const draw = this.pageDrawers[id];
            const m = MODULES.find(x => x.page === id);
            const box = {x, y: bar, width: column.width};
            // Whether the page is on screen, for its Kapa (`kapaAwake` in `pageView`).
            const visible = this.expanded && (id === this.selected || this.travel !== 0);
            const ctx = m ? {...model, module: this.model.modules?.[m.id], visible} : {...model, visible};
            // Only the page chosen is heard (`.accessibilityHidden(candidate != shownPage)`).
            this._unheard = id !== this.selected;
            // On the page chosen, at rest, a Kapa may take her room on a layer: inside the
            // page, and off the margins its edges fade over while there are pages to turn.
            const margin = pages.length > 1 ? Metrics.pageMargin : 0;
            this._pageClip = this._roomsNow && id === this.selected
                ? {x: Math.max(x, column.x) + margin, y: bar, w: column.width - 2 * margin, h: Metrics.pageHeight} : null;
            try {
                g.clipped(cr => {
                    cr.rectangle(column.x, bar, column.width, Metrics.pageHeight);
                }, () => draw?.(g, this, box, ctx));
            } finally {
                this._unheard = false;
                this._pageClip = null;
            }
        });
        this.fadePageEdges(g, column);
        this.drawSwitcher(g, column);
    }

    /**
     * Turning, a page fades out over the margin every page keeps to its edge, rather than running on
     * to the outline and being cut there. The surface is black, so a black gradient over the margins
     * is the mask (`.mask { clear → black over `pageMargin`, black, black → clear }`).
     */
    fadePageEdges(g, column) {
        if (this.model.pages.length < 2)
            return;
        const margin = Metrics.pageMargin;
        const top = this.geometry.barHeight, height = Metrics.pageHeight;
        for (const [x0, x1, from, to] of [
            [column.x, column.x + margin, 1, 0],
            [column.x + column.width, column.x + column.width - margin, 1, 0],
        ]) {
            const cr = g.cr;
            cr.save();
            cr.newPath();
            cr.rectangle(Math.min(x0, x1), top, margin, height);
            cr.setSourceLinear(x0, 0, x1, 0, [[0, 0, 0, 0, from], [1, 0, 0, 0, to]]);
            cr.fill();
            cr.restore();
        }
    }

    /**
     * Where the pages stand: the page chosen, moved by the fingers (`follow`, which
     * gives a third as far beyond either end), and on its way back after a turn.
     * The spring's own overshoot past an end is not given way to again.
     */
    stripPosition() {
        return this.pagePosition.value;
    }

    pageModel() {
        const m = this.model;
        return {
            providers: m.providers,
            offered: m.offered,
            highlighted: this.highlighted,
            fullscreen: !!this.fullscreen,
            expanded: this.expanded,
            selectedPage: this.selected,
            scene: this,
            call: (module, method, args) => this.actions.call?.(module, method, args),
            now: this.now,
            showsKapa: m.showsKapa !== false,
            rowLayer: this.layers.has('row'),
            layers: this.layers,
            drawKapa: (g, key, x, y, size, expression, options) => this.drawKapaAt(g, key, x, y, size, expression, options),
            capacityFocus,
            refresh: p => this.actions.refresh?.(p),
            connect: p => this.actions.connect?.(p),
            // The page's own way to Settings is for connecting a Provider.
            openSettings: (section = 'providers') => this.actions.openSettings?.(section),
            model: m,
        };
    }

    /** One page button's motion: how lit (the pointer on it) and how pressed (the button down). */
    switcherState(id) {
        let state = this.switcher.get(id);
        if (!state) {
            // How much it is the page shown: 1 for it, 0 for the rest, and between while a turn changes it.
            const current = new Spring(id === this.selected ? 1 : 0, 0.42, 0.8, {epsilon: 0.002});
            state = {current, lit: new Fade(0), press: new Fade(0), isLit: false, isPressed: false, dotShown: false};
            this.switcher.set(id, state);
        }
        return state;
    }

    setPageLit(id, lit) {
        const state = this.switcherState(id);
        if (state.isLit === lit)
            return;
        state.isLit = lit;
        // `.animation(.easeOut(duration: 0.12), value: lit)`
        state.lit.start(lit ? 1 : 0, 0.12, 0, ease.out, this.clockNow());
        this.onChange();
    }

    setPagePressed(id, pressed) {
        const state = this.switcherState(id);
        if (state.isPressed === pressed)
            return;
        state.isPressed = pressed;
        // `PageButtonStyle`: a little smaller and darker while it is down, `easeOut(duration: 0.1)`.
        state.press.start(pressed ? 1 : 0, 0.1, 0, ease.out, this.clockNow());
        this.onChange();
    }

    /** The page button the keyboard is on, or null. */
    get focusedPage() {
        return this.focused?.startsWith('page:') ? this.focused.slice(5) : null;
    }

    set focusedPage(page) {
        this.focused = page ? `page:${page}` : null;
    }

    /**
     * The keyboard moves (Tab, Shift-Tab) among the controls that take it, in the order
     * they were drawn: the cards' buttons, then the page buttons while they show, as
     * SwiftUI walks the column top to bottom. Past either end it leaves them.
     */
    focusNext(by) {
        const order = this.hits.filter(h => h.focusable);
        if (order.length === 0)
            return false;
        const at = order.findIndex(h => h.id === this.focused);
        const next = at < 0 ? (by > 0 ? 0 : order.length - 1) : at + by;
        this.focused = next < 0 || next >= order.length ? null : order[next].id;
        this.onChange();
        return this.focused !== null || at >= 0;
    }

    /** Space or Return takes the control the keyboard is on. */
    activateFocused() {
        const hit = this.focused ? this.hits.find(h => h.focusable && h.id === this.focused) : null;
        if (!hit?.onClick)
            return false;
        hit.onClick();
        this.onChange();
        return true;
    }

    /** The row of dots under the page, which become buttons as the pointer comes down to them. */
    drawSwitcher(g, column) {
        const pages = this.model.pages;
        if (pages.length < 2)
            return;
        const bar = this.geometry.barHeight;
        const k = this.controls.value; // 0 dots, 1 buttons
        const slot = 8 + (22 - 8) * k;
        const spacing = 4;
        const total = pages.length * slot + (pages.length - 1) * spacing;
        const top = bar + Metrics.pageHeight + 4;
        const cx = column.x + column.width / 2;
        let x = cx - total / 2;
        pages.forEach(id => {
            const current = id === this.selected;
            const state = this.switcherState(id);
            // The page shown changed without a turn (its Module gone, a test): so has its dot.
            if (state.current.target !== (current ? 1 : 0))
                state.current.shift(current ? 1 : 0);
            const shown = state.current.value;
            this.setPageLit(id, this.controlsShown && this.isHovered(`page:${id}`));
            const lit = state.lit.value;
            const pressed = state.press.value;
            const size = 6 + (22 - 6) * k;
            const bx = x + (slot - size) / 2, by = top + (slot - size) / 2;
            const midX = bx + size / 2, midY = by + size / 2;
            // A dot is bright for the page shown and faint for the rest; a button is a quiet square,
            // brighter for the page shown and between the two under the pointer.
            // A turn changes them on its own spring, as it does the colour (`fill(lit:)` under `withAnimation`).
            const dotAlpha = 0x3D / 255 + (0xB3 / 255 - 0x3D / 255) * shown;
            const quiet = 0x2E / 255 + (0x4D / 255 - 0x2E / 255) * lit;
            const buttonAlpha = quiet + (0x66 / 255 - quiet) * shown;
            const alpha = Math.min(Math.max(dotAlpha + (buttonAlpha - dotAlpha) * k, 0), 1);
            const dark = 0.05 * pressed; // `.brightness(-0.05)`
            g.save();
            if (pressed > 0) {
                const scale = 1 - 0.1 * pressed; // `.scaleEffect(0.9)`
                g.translate(midX, midY);
                g.cr.scale(scale, scale);
                g.translate(-midX, -midY);
            }
            g.fillRoundRect(bx, by, size, size, 3 + k, [1 - dark, 1 - dark, 1 - dark, alpha]);
            if (k > 0.02) {
                // The icon fades in as one picture (`.opacity(isButton ? 1 : 0)`).
                g.group(k, () => {
                    const faint = 0x97 / 255 + (1 - 0x97 / 255) * lit;
                    const gray = Math.min(faint + (1 - faint) * shown, 1) - dark;
                    drawIcon(g, PAGE_ICON[id], midX, midY, 0.25 + 0.5 * k, [gray, gray, gray]);
                });
            }
            g.restore();
            // The running dot is there while the dots are buttons (`if isRunning && isButton`):
            // it fades in and out with them, on their spring (`.transition(.opacity)`
            // in the buttons' own animation), and a Module starting or stopping while
            // they show puts it there or takes it away at once, as nothing animates that.
            const running = this.moduleRunning(id);
            if (!running)
                state.dotShown = false;
            else if (this.controlsShown)
                state.dotShown = true;
            const dot = state.dotShown ? Math.min(Math.max(k, 0), 1) : 0;
            if (dot > 0.01) {
                g.group(dot, () => {
                    g.fillCircle(bx + size + 2 - 3.5, by - 2 + 3.5, 5, Colors.black);
                    g.fillCircle(bx + size + 2 - 3.5, by - 2 + 3.5, 3.5, Colors.red);
                });
            }
            if (this.controlsShown) {
                const hit = {x, y: top, w: slot, h: 22};
                this.addHit({
                    id: `page:${id}`, ...hit, cursor: 'pointer', label: t(PAGE_NAME[id]),
                    // Heard as a page, the one shown as chosen; reached with the keyboard,
                    // its ring round the button as drawn.
                    role: 'tab', selected: current, focusable: true,
                    ring: {x: bx, y: by, w: size, h: size, radius: 3}, onClick: () => this.select(id),
                    // A Button acts on the release, if the pointer is still on it.
                    onDrag: (px, py, phase) => {
                        const inside = px >= hit.x && px < hit.x + hit.w && py >= hit.y && py < hit.y + hit.h;
                        if (phase === 'ended') {
                            this.setPagePressed(id, false);
                            if (inside)
                                this.select(id);
                        } else {
                            this.setPagePressed(id, inside);
                        }
                    },
                });
            }
            // The tip comes and goes as one picture (`.transition(.opacity)`).
            if (lit > 0.01)
                g.group(lit, () => this.drawPageTip(g, t(PAGE_NAME[id]), midX, by));
            x += slot + spacing;
        });
    }

    moduleRunning(page) {
        const m = MODULES.find(x => x.page === page);
        return !!m?.running?.({...this.pageModel(), module: this.model.modules?.[m.id]});
    }

    /** The page's name above its button, while the pointer is on it. */
    drawPageTip(g, name, cx, buttonTop) {
        const font = Type.geist(11, 500);
        const w = g.measureText(name, font) + 14;
        const x = cx - w / 2, y = buttonTop - 27;
        g.fillRoundRect(x, y, w, 19, 6, [0x2C / 255, 0x2C / 255, 0x2C / 255]);
        g.strokeRoundRect(x + 0.5, y + 0.5, w - 1, 18, 5.5, [1, 1, 1, 0.1], 1);
        g.drawText(name, x + 7, y + (19 - g.lineHeight(font)) / 2, font, Colors.white);
    }
}
