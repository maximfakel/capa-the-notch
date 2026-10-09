// Port of NotchGeometry and SurfaceOutline. y runs down.

/** The room every open page has under the strip, whatever it shows. */
export const PAGE_HEIGHT = 152;
/** The page dots under it, at rest. */
export const PAGE_SWITCHER_HEIGHT = 20;
export const MINIMUM_SURFACE_WIDTH = 560;
/** The inside curve where the shape meets the bar either side. */
export const SHOULDER = 20;
export const COMPACT_RADIUS = 22;
export const OPEN_RADIUS = 38;

/**
 * There is no physical notch on this screen, so the notch is zero wide and the
 * surface takes its height from the top bar rather than from a number chosen
 * by eye.
 */
export class Geometry {
    /** @param maxHeight the room the screen leaves the surface (its work area), if known */
    constructor(barHeight, notchWidth = 0, maxHeight = Infinity) {
        this.barHeight = barHeight;
        this.notchWidth = notchWidth;
        this.maxHeight = maxHeight;
    }

    /** Never taller than the screen has room for (`min(fittingSize, visibleFrame.height)`). */
    get openHeight() {
        return Math.min(this.barHeight + PAGE_HEIGHT + PAGE_SWITCHER_HEIGHT, this.maxHeight);
    }

    surfaceWidth(providerWidth = 170) {
        return Math.max(this.notchWidth + providerWidth * 2, MINIMUM_SURFACE_WIDTH);
    }

    /**
     * 370 over a 185-point notch at default scaling, 410 over a 220-point one;
     * the narrower when there is no notch.
     */
    compactWidth() {
        const drawn = this.notchWidth > 200 ? 410 : 370;
        return Math.min(Math.max(drawn, this.notchWidth + 185), this.surfaceWidth());
    }
}

/**
 * The surface's outline as one path: square along the top, where it meets the
 * bar, with a shoulder curving out into the bar either side, rounded along the
 * bottom. `x0` is the shape's left edge in the context.
 */
export function addOutline(cr, x0, top, width, height, radius) {
    if (width <= 0 || height <= 0)
        return;
    const x1 = x0 + width;
    const bottom = top + height;
    const r = Math.min(SHOULDER, height, width / 2);
    // A shoulder and a corner share the side: on a strip too short for both,
    // the corner gives way and the side is one curve.
    const corner = Math.max(0, Math.min(radius, width / 2, height - r));
    const unit = r / 12;
    const arc = corner * 0.552;

    cr.moveTo(x0 - r, top);
    cr.curveTo(x0 - 0.529 * unit, top, x0 - 0.211 * unit, top + 7.2 * unit, x0, top + r);
    cr.lineTo(x0, bottom - corner);
    cr.curveTo(x0, bottom - corner + arc, x0 + corner - arc, bottom, x0 + corner, bottom);
    cr.lineTo(x1 - corner, bottom);
    cr.curveTo(x1 - corner + arc, bottom, x1, bottom - corner + arc, x1, bottom - corner);
    cr.lineTo(x1, top + r);
    cr.curveTo(x1 + 0.211 * unit, top + 7.2 * unit, x1 + 0.529 * unit, top, x1 + r, top);
    cr.closePath();
}

/**
 * The surface's motion: a spring, opening with a little give (response 0.42,
 * damping 0.8) and closing without any (0.45, 1.0). Returns the progress of
 * the move, 0 to 1 and a little over while it gives.
 */
export function spring(t, opening) {
    const response = opening ? 0.42 : 0.45;
    const damping = opening ? 0.8 : 1.0;
    const omega = (2 * Math.PI) / response;
    if (damping >= 1)
        return 1 - Math.exp(-omega * t) * (1 + omega * t);
    const dampedOmega = omega * Math.sqrt(1 - damping * damping);
    const decay = Math.exp(-damping * omega * t);
    return 1 - decay * (Math.cos(dampedOmega * t) + (damping * omega / dampedOmega) * Math.sin(dampedOmega * t));
}

/** How long a spring takes to be indistinguishable from rest. */
export const SPRING_SETTLE_SECONDS = 1.0;
