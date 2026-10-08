// What the panel controller does with the pointer: the surface watches where
// the pointer is, rather than waiting to be told it arrived (`readPointer` in
// NotchPanelController.swift). The pointer is read on a beat; it must settle
// before the surface opens, and be gone for a moment before it closes.
//
// A surface gives it a `host`:
//   pointer()      the pointer on the screen, in pixels from the screen's top
//                  left, or null when it cannot be read
//   buttons()      whether a mouse button is held
//   monitor()      {x, y, width, height} of the display the surface hangs from
//   window()       {x, y} of the scene's (0, 0) on the screen
//   passThrough(bool)  let the pointer through the window (true) or take it

import {Metrics} from './metrics.js';

export class SurfaceController {
    constructor(scene, host) {
        this.scene = scene;
        this.host = host;
        this.presentTicks = 0;
        this.absentTicks = 0;
        /** Open for a test or a hand-over, whatever the pointer does. */
        this.heldOpen = false;
        /** The Teleprompter keeps a passing pointer from opening the surface over it. */
        this.hoverOpens = () => scene.hoverOpens();
        this._timer = 0;
        /** A file carried over the surface: the page it showed, whether it opened it, whether it was dropped. */
        this._fileDrop = null;
        this._dropNear = false;
        this._dragReleased = 0;
    }

    start(setInterval = globalThis.setInterval) {
        if (this._timer)
            return;
        this._timer = setInterval(() => this.read(), Metrics.pointerInterval * 1000);
    }

    stop(clearInterval = globalThis.clearInterval) {
        if (this._timer)
            clearInterval(this._timer);
        this._timer = 0;
        this.scene.setPointerNear(false);
        this.presentTicks = this.absentTicks = 0;
    }

    /** Timers: the surface's own (`host.timers`), or the page's. */
    _timers() {
        return this.host.timers ?? {
            set: (fn, ms) => globalThis.setTimeout(fn, ms),
            clear: id => globalThis.clearTimeout(id),
        };
    }

    /**
     * The shape, in screen coordinates: the one it is moving to, as Swift reads
     * `shape.size`, so an opening surface answers at once to where it will be.
     */
    surface() {
        const m = this.host.monitor();
        const cx = m.x + m.width / 2;
        const r = this.scene.shapeTargetRect(cx);
        return {x: r.x, y: m.y, w: r.w, h: r.h};
    }

    /** What the closed surface answers to: its strip, and only the strip. */
    strip() {
        const m = this.host.monitor();
        const w = this.scene.compactWidth;
        return {x: m.x + m.width / 2 - w / 2, y: m.y, w, h: this.scene.geometry.barHeight};
    }

    static contains(rect, p, by = 0) {
        return p.x >= rect.x - by && p.x <= rect.x + rect.w + by && p.y >= rect.y - by && p.y <= rect.y + rect.h + by;
    }

    read() {
        const scene = this.scene;
        const mouse = this.host.pointer();
        if (!mouse)
            return;
        const surface = this.surface();
        // Over the shape, or over what a Module hangs under it (the Dictation Capsule).
        const mon = this.host.monitor();
        const hung = this.scene.overlays(mon.x + mon.width / 2).some(o => {
            const frame = {x: o.frame.x, y: mon.y + o.frame.y, w: o.frame.width, h: o.frame.height};
            return SurfaceController.contains(frame, mouse);
        });
        const over = SurfaceController.contains(surface, mouse) || hung;
        // Around the shape the window is transparent. It lets the pointer
        // through there, and takes it only over the shape itself.
        // With a button held and the pointer near the surface a file may be on its way
        // to it: the window takes the pointer, or the drop would go through it.
        const dragNear = !!this.host.buttons?.() && SurfaceController.contains(scene.expanded ? surface : this.strip(), mouse, Metrics.nearDistance);
        this.host.passThrough?.(!over && !dragNear);

        this.followPageSwitcher(surface, mouse);

        const origin = this.host.window();
        scene.setPointer(scene.expanded && over ? {x: mouse.x - origin.x, y: mouse.y - origin.y} : null);
        // Kapa's eyes follow the pointer over the shape, closed or open; a carried file is looked at instead.
        scene.setShapePointer(over && !this._fileDrop ? {x: mouse.x - origin.x, y: mouse.y - origin.y} : null);

        // Closed, the surface answers to its strip; open, to the whole of itself.
        const region = scene.expanded ? surface : this.strip();

        // Closed, the surface grows a little as the pointer comes near it, before
        // it is over it and long before it opens.
        scene.setPointerNear(!scene.expanded && SurfaceController.contains(region, mouse, Metrics.nearDistance));

        if (SurfaceController.contains(region, mouse)) {
            this.absentTicks = 0;
            // A button held down is a drag on its way somewhere, not a pointer resting on the strip;
            // nor is a file being carried over it.
            if (this.host.buttons?.() || this._fileDrop) {
                this.presentTicks = 0;
                return;
            }
            // While the Script runs, a passing pointer does not open the surface over it.
            if (!this.hoverOpens()) {
                this.presentTicks = 0;
                return;
            }
            this.presentTicks += 1;
            if (this.presentTicks >= Metrics.presentTicksBeforeOpen)
                scene.expand();
            return;
        }

        this.presentTicks = 0;

        // A pinned surface was asked for: it waits to be dismissed. Nor while a file is
        // carried over it: the drag decides, and a pointer that wanders a little off the
        // shape on its way to the drop area has not left.
        if (!scene.expanded || scene.pinned || this.heldOpen || this._fileDrop) {
            this.absentTicks = 0;
            return;
        }
        this.absentTicks += 1;
        if (this.absentTicks >= Metrics.absentTicksBeforeClose) {
            this.absentTicks = 0;
            scene.collapse();
        }
    }

    /**
     * Open, the page dots become buttons as the pointer comes down to them, and
     * the surface lets itself down to hold them; they go back to dots once it
     * has moved well away, so the edge of the reach does not flicker.
     */
    followPageSwitcher(surface, mouse) {
        const scene = this.scene;
        let shown = false;
        if (scene.expanded && scene.model.pages.length > 1
            && mouse.x >= surface.x && mouse.x <= surface.x + surface.w && mouse.y <= surface.y + surface.h) {
            const fromBottom = surface.y + surface.h - mouse.y;
            shown = scene.controlsShown ? fromBottom < Metrics.switcherLeaves : fromBottom < Metrics.switcherReach;
        }
        scene.setControlsShown(shown);
    }

    // MARK: - A file carried over the surface (the Shelf's)

    _shelfCall(method, args) {
        return this.scene.actions.call?.('shelf', method, args)?.catch?.(() => {});
    }

    get shelfOn() {
        return !!this.scene.model.modules?.shelf?.view?.enabled;
    }

    /**
     * A file is being carried at `point` (screen pixels). Near the closed strip, or over
     * the open surface, the Shelf opens on its Files and shows where to drop; carried
     * elsewhere it lets go (`followFileDrag`).
     */
    fileDrag(point) {
        const scene = this.scene;
        if (!this.shelfOn || !point)
            return;
        this._timers().clear(this._dragReleased);
        this._dragReleased = 0;
        const region = scene.expanded ? this.surface() : this.strip();
        const wanted = SurfaceController.contains(region, point, Metrics.nearDistance);
        if (wanted && !this._fileDrop)
            this._beginFileDrop();
        else if (!wanted && this._fileDrop)
            this._endFileDrop();
        // Kapa watches the file: where it is, in the surface's coordinates.
        if (this._fileDrop) {
            const origin = this.host.window();
            scene.setDragPoint({x: point.x - origin.x, y: point.y - origin.y});
        }
        // Near the drop area, the area makes room for Kapa to take the file.
        const area = scene.shelfDropArea;
        if (this._fileDrop && area) {
            const o = this.host.window();
            const near = SurfaceController.contains({x: area.x + o.x, y: area.y + o.y, w: area.w, h: area.h}, point, 28);
            if (near !== this._dropNear) {
                this._dropNear = near;
                this._shelfCall('dropNear', {value: near});
            }
        }
    }

    _beginFileDrop() {
        const scene = this.scene;
        this._fileDrop = {page: scene.selected, opened: !scene.expanded, dropped: false};
        this._dropNear = false;
        this._shelfCall('setTab', {tab: 'files'});
        scene.select('shelf');
        this._shelfCall('dropTargeted', {value: true});
        if (!scene.expanded)
            scene.expand();
    }

    /** The file went elsewhere, or was let go and dropped: the drop area goes; not dropped, the surface goes back as it was. */
    _endFileDrop() {
        const drop = this._fileDrop;
        if (!drop)
            return;
        this._fileDrop = null;
        this._dropNear = false;
        this.scene.setDragPoint(null);
        this._shelfCall('dropTargeted', {value: false});
        this._shelfCall('dropNear', {value: false});
        if (drop.dropped)
            return;
        const scene = this.scene;
        if (drop.opened && scene.expanded && !scene.pinned)
            scene.collapse();
        if (scene.model.pages.includes(drop.page))
            scene.select(drop.page);
    }

    /** The drag ended without a drop: a drop is delivered a moment after the button goes up, so wait for it. */
    fileDragEnded() {
        if (!this._fileDrop || this._dragReleased)
            return;
        this._dragReleased = this._timers().set(() => {
            this._dragReleased = 0;
            this._endFileDrop();
        }, 600);
    }

    /** Files were dropped: Kapa eats them, they are added, and the Shelf shows them under Files. */
    fileDropped(add) {
        const scene = this.scene;
        // A drop read slowly must not find the surface closed by the leave's timer under it.
        if (this._dragReleased) {
            this._timers().clear(this._dragReleased);
            this._dragReleased = 0;
        }
        if (this._fileDrop)
            this._fileDrop.dropped = true;
        scene.actions.sound?.('shelfTook');
        // One word to the hub: Kapa swallows, and the drop area and its nearness go.
        this._shelfCall('dropped', {reduceMotion: scene.reduced});
        Promise.resolve(add?.()).catch(() => {}).then(() => {
            this._shelfCall('setTab', {tab: 'files'});
            if (scene.expanded)
                scene.select('shelf');
            this._endFileDrop();
        });
    }

    /** A click elsewhere dismisses a pinned surface. */
    focusLost() {
        if (this.scene.pinned)
            this.scene.dismiss();
    }

    /** Escape and the arrow keys, while the surface is pinned and so can hear them. */
    key(name) {
        const scene = this.scene;
        if (name === 'Escape' && scene.pinned) {
            scene.dismiss();
            return true;
        }
        if (scene.expanded) {
            // The cards' buttons, and the page buttons while they show, reached with the keyboard.
            if (name === 'Tab' || name === 'ShiftTab')
                return scene.focusNext(name === 'Tab' ? 1 : -1);
            if ((name === 'Space' || name === 'Enter') && scene.activateFocused())
                return true;
        }
        if (scene.expanded && scene.model.pages.length > 1) {
            if (name === 'ArrowLeft') {
                scene.step(-1);
                return true;
            }
            if (name === 'ArrowRight') {
                scene.step(1);
                return true;
            }
        }
        return false;
    }

    /**
     * Two fingers on the open surface: the pages follow them, and a swipe that
     * ends past forty points turns one. `phase` is 'began', 'changed' or 'ended'.
     */
    swipe(phase, deltaX = 0) {
        const scene = this.scene;
        if (!scene.expanded || scene.model.pages.length < 2)
            return false;
        // A swipe that starts over a row that overflows is the row's, all of it, its
        // glide included: the files scroll, the page stays. Decided again at the start
        // of every gesture.
        if (phase === 'began') {
            const r = scene.scrollableRow;
            this._rowSwipe = !!r && scene.pointerIn(r.x, r.y, r.w, r.h);
        }
        if (this._rowSwipe) {
            if (phase === 'changed')
                scene.scroll(deltaX);
            else if (phase !== 'began')
                this._rowSwipe = false;
            return true;
        }
        switch (phase) {
        case 'began':
            this._swipe = 0;
            scene.follow(0);
            break;
        case 'changed':
            this._swipe = (this._swipe ?? 0) + deltaX;
            scene.follow(this._swipe);
            this._timers().clear(this._quiet);
            // The end of a swipe can be lost: silence for a third of a second ends it where it is.
            this._quiet = this._timers().set(() => {
                if (this._swipe) {
                    scene.settle(this._swipe);
                    this._swipe = 0;
                }
            }, 350);
            break;
        default:
            this._timers().clear(this._quiet);
            scene.settle(this._swipe ?? 0);
            this._swipe = 0;
        }
        return true;
    }
}
