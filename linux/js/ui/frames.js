// The surface's frames: one chain of them, due at the soonest moment anything
// asked for, and none at all while nothing moves. A host gives it a clock, its
// timers and the things it can draw (the whole surface, and the small layers
// over it that hold what moves while the rest is still), and tells it when each
// has been drawn: what is next is decided then, from what that drawing asked
// for, never from what the one before asked.
//
// A host gives it:
//   clock()          now, in milliseconds on the clock the scene is ticked in (as seconds)
//   set(fn, ms)      a timer, its id; clear(id) takes one back
//   nextFrame(fn)    optional: fn at the screen's next frame, before it is drawn, its id
//                    (0 if it cannot); clearFrame(id) takes one back. A motion is then
//                    drawn at the moments the screen shows it, from the very first frame.
//   drawWhole()      lays the surface out and asks for it to be drawn
//   drawLayer(key)   asks for one layer to be drawn
//   placeLayers()    shows the layers in use (`scene.layers`), each placed over what it draws, and hides the rest

/** The springs and fades want every frame. */
export const FRAME_MS = 16;
/** Kapa, a Module's beat, and anything asked for at a moment: a frame at most every thirtieth of a second. */
export const KAPA_FRAME_MS = 33;

export class FrameChain {
    constructor(scene, host) {
        this.scene = scene;
        this.host = host;
        /** Something changed since the surface was last drawn: the next frame draws all of it. */
        this.stale = true;
        /** When the surface itself is next to be drawn (ms), apart from the layers. */
        this.wholeDue = Infinity;
        /** When each layer is next to be drawn (ms), as its last drawing asked, by key. */
        this.layerDue = new Map();
        this._frame = 0;
        this._frameDue = Infinity;
        /** Whether the frame pending is the screen's own (`nextFrame`) rather than a timer. */
        this._onScreen = false;
        this._timed = 0;
        /** What the surface's last drawing asked of it (`scene.kapaDue`): the layer may ask for sooner. */
        this._kapaAsked = Infinity;
    }

    /**
     * Draws all of the surface soon. A frame already due within `keep` ms will
     * do; one further off is brought forward to the next frame.
     */
    wake(keep = FRAME_MS) {
        this.stale = true;
        this.schedule(FRAME_MS, null, keep);
    }

    /** A frame in `ms`, of the whole surface, or of the layer `layer` alone; one due within `keep` will do. */
    schedule(ms, layer = null, keep = ms) {
        const now = this.host.clock();
        const due = now + ms;
        this._due(due, layer);
        this._arm(due, now + Math.max(ms, keep));
    }

    _due(due, layer) {
        if (layer === null)
            this.wholeDue = Math.min(this.wholeDue, due);
        else
            this.layerDue.set(layer, Math.min(this.layerDue.get(layer) ?? Infinity, due));
    }

    /**
     * One chain of frames, ever, due at the soonest time anything asked for: a
     * frame asked for while one is pending is kept if that one is due by
     * `keep`, else replaces it, never left beside it as a second chain that
     * would never stop.
     */
    _arm(due, keep = due) {
        if (this._frame) {
            if (this._frameDue <= keep)
                return;
            this._cancel();
        }
        this._frameDue = due;
        const ms = due - this.host.clock();
        // Wanted by the next frame: the screen's own next frame, where the host has one.
        if (ms <= FRAME_MS && this.host.nextFrame) {
            this._frame = this.host.nextFrame(() => this._run());
            this._onScreen = !!this._frame;
            if (this._frame)
                return;
        }
        this._onScreen = false;
        this._frame = this.host.set(() => this._run(), Math.max(1, Math.round(ms)));
    }

    _cancel() {
        if (this._onScreen)
            this.host.clearFrame(this._frame);
        else
            this.host.clear(this._frame);
        this._frame = 0;
        this._onScreen = false;
    }

    _run() {
        this._frame = 0;
        this._onScreen = false;
        this._frameDue = Infinity;
        const scene = this.scene;
        const now = this.host.clock() / 1000;
        const moving = scene.tick(now);
        this._draw(now, moving);
        if (moving) {
            this.schedule(FRAME_MS);
        } else {
            // Nothing of the surface's own moves: the next frame after a pause starts
            // with no time gone, not with a jump the length of the pause.
            scene._lastNow = null;
        }
        // What was asked for and not drawn this frame keeps its place; what the
        // drawing asks for is added once it has drawn (`painted`).
        const next = Math.min(this.wholeDue, ...this.layerDue.values());
        if (Number.isFinite(next))
            this._arm(next);
    }

    /**
     * Draws what this frame needs: the whole surface when something changed or
     * moved or its moment came, and each layer in use when its own moment came,
     * or with the whole when something changed, when it has just been placed, or
     * when the surface draws a part of what it holds (the row's Kapa over the
     * strip) — not when only the surface's own moment came: a page's beat does
     * not draw its Kapa again, as Swift draws her Canvas apart from the page. Which
     * layers are in use is decided with the whole surface, before either is drawn,
     * so a part is never drawn twice or not at all in the frame it changes hands;
     * nothing that changes it comes without waking the whole.
     */
    _draw(now, moving) {
        const scene = this.scene;
        // A frame timed for a moment can come a little before it.
        const at = now * 1000 + 2;
        const changed = this.stale || moving;
        const whole = changed || at >= this.wholeDue;
        if (whole) {
            this.stale = false;
            this.wholeDue = Infinity;
            scene.planLayers();
            this.host.drawWhole();
            this.host.placeLayers();
        }
        // A moment a layer asked for is over once it comes, drawn or not (the layer
        // gone since); a layer drawn now asks again once it is drawn.
        for (const [key, layer] of scene.layers) {
            const due = at >= (this.layerDue.get(key) ?? Infinity);
            if (due || whole && (changed || layer.fresh || layer.shared)) {
                this.layerDue.delete(key);
                this.host.drawLayer(key);
            }
        }
        for (const [key, when] of this.layerDue) {
            if (at >= when || !scene.layers.has(key))
                this.layerDue.delete(key);
        }
    }

    /**
     * The surface (`'whole'`) or a layer (`'layer'`, and its key) has just been drawn:
     * the next frame is what that drawing asked for (`scene.kapaDue`, the layer's
     * `due`, seconds on the scene's clock), counted from the frame it was drawn
     * for. Kapa at her own cadence (`KapaSchedule`), a Module at its beat, the bars at theirs.
     */
    painted(which, key = null) {
        const scene = this.scene;
        const from = scene.now * 1000;
        const at = due => Math.max(from + KAPA_FRAME_MS, due * 1000);
        if (which === 'layer') {
            const due = scene.layers.get(key)?.due ?? Infinity;
            if (Number.isFinite(due))
                this._ask(at(due), key);
            // A layer may ask for the surface too: what of Kapa floats up over the strip is the surface's to draw.
            if (scene.kapaDue < this._kapaAsked) {
                this._kapaAsked = scene.kapaDue;
                this._ask(at(scene.kapaDue));
            }
            return;
        }
        this._kapaAsked = scene.kapaDue;
        if (scene.modulesNeedFrames())
            this._ask(from + KAPA_FRAME_MS);
        else if (Number.isFinite(scene.kapaDue))
            this._ask(at(scene.kapaDue));
        else if (!scene.idle)
            this._ask(from + KAPA_FRAME_MS);
        else
            this._scheduleTimed();
    }

    _ask(due, layer = null) {
        this._due(due, layer);
        this._arm(due);
    }

    /** At rest, a frame when something asks for one on a beat (a Module, the reset times). */
    _scheduleTimed() {
        if (this._timed)
            this.host.clear(this._timed);
        this._timed = 0;
        const delay = this.scene.timedRedrawDelay();
        if (!Number.isFinite(delay))
            return;
        this._timed = this.host.set(() => {
            this._timed = 0;
            this.wake();
        }, Math.max(KAPA_FRAME_MS, Math.round(delay * 1000)));
    }

    destroy() {
        if (this._frame)
            this._cancel();
        if (this._timed)
            this.host.clear(this._timed);
        this._frame = this._timed = 0;
    }
}
