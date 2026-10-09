// Which pose, from what the surface knows — a port of `KapaMood` in
// `linux/crates/core/src/kapa/mood.rs`, reading the `ProviderView` JSON a surface
// receives (`linux/crates/core/src/view.rs`) instead of a snapshot. The daemon can
// also send the Rust answer; the two are checked against each other in the
// tests.

const URGENCY = {worried: 0, waiting: 1, puzzled: 2, stale: 3, focused: 4};
export const urgency = expression => URGENCY[expression] ?? 5;

/**
 * One Provider's pose, from its connection and the window with the least
 * left. Old numbers get no judgement: stale and connecting look the same.
 */
export function capacityMood(view) {
    switch (view.state) {
    case 'disconnected': return 'puzzled';
    case 'connecting':
    case 'stale': return 'stale';
    default: {
        const window = view.windows.find(w => w.id === view.headline);
        if (!window) return 'rest';
        if (window.remainingFraction <= 0) return 'waiting';
        switch (window.pace) {
        case 'sustainable': return 'rest';
        case 'tightening': return 'focused';
        default: return 'worried';
        }
    }
    }
}

/**
 * One Kapa a page: on the card that explains the pose, which is the one
 * needing the most attention. A tie goes to the card that comes first.
 * Returns `{provider, expression}` or null.
 */
export function capacityFocus(views) {
    let best = null;
    for (const view of views) {
        const expression = capacityMood(view);
        const u = urgency(expression);
        if (best === null || u < best.urgency)
            best = {provider: view.provider, expression, urgency: u};
    }
    return best && {provider: best.provider, expression: best.expression};
}

export const musicMood = isPlaying => isPlaying ? 'music' : 'paused';
