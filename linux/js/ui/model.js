// What the scene reads, derived from the hub's state. The decisions that are
// not about drawing — which windows the strip shows, which pages there are —
// are the hub's; this is the part of them a surface still has to do until the
// hub sends them whole (`CompactStrip`, `SurfaceCards`, `SurfacePageOrder`).

const PROVIDER_ORDER = ['codex', 'claudeCode', 'openCode'];

const byDuration = windows =>
    [...windows].sort((a, b) => (a.durationMinutes ?? Infinity) - (b.durationMinutes ?? Infinity));

const sideFor = (provider, window) => ({
    provider,
    figure: window ? `${Math.round(window.remainingPercentage)}%` : '—',
    pace: window ? window.pace : null,
});

/**
 * What the closed strip shows either side of the notch. Two Providers on:
 * each the window chosen in Settings — its five hours unless asked otherwise.
 * One on: that Provider alone, its shortest window left and its longest right.
 */
export function stripSides(providers, showing = 'fiveHour') {
    const on = providers.filter(p => !p.switchedOff)
        .sort((a, b) => PROVIDER_ORDER.indexOf(a.provider) - PROVIDER_ORDER.indexOf(b.provider));
    if (on.length === 0)
        return {left: null, right: null};
    if (on.length === 1) {
        const only = on[0];
        const windows = byDuration(only.windows);
        if (windows.length === 0)
            return {left: sideFor(only.provider, null), right: null};
        if (windows.length === 1)
            return {left: sideFor(only.provider, windows[0]), right: null};
        return {left: sideFor(only.provider, windows[0]), right: sideFor(only.provider, windows.at(-1))};
    }
    const chosen = view => {
        if (!view)
            return null;
        const windows = byDuration(view.windows);
        const headline = view.windows.find(w => w.id === view.headline) ?? null;
        // The window of that length, and only without one the nearest end.
        const window = showing === 'weekly'
            ? windows.find(w => w.durationMinutes === 7 * 24 * 60) ?? windows.at(-1)
            : showing === 'leastLeft'
                ? headline
                : windows.find(w => w.durationMinutes === 5 * 60) ?? windows[0];
        return sideFor(view.provider, window ?? null);
    };
    return {left: chosen(on[0]), right: chosen(on[1])};
}

/** The scene's model from the hub's state. */
export function deriveModel(state, extra = {}) {
    const providers = state?.providers ?? [];
    return {
        providers,
        strip: state?.strip ?? stripSides(providers, state?.compactWindow),
        pages: state?.pages ?? ['capacity'],
        language: state?.language ?? 'en',
        modules: state?.modules ?? {},
        showsKapa: state?.showsKapa ?? true,
        screenSharingAllowed: state?.screenSharingAllowed ?? false,
        // 'system', 'light' or 'dark', when the hub says; the Dictation capsule follows it.
        appearance: state?.appearance ?? 'system',
        ...extra,
    };
}

/** Whether two values from the hub are the same, all the way down (plain data: no cycles, no functions). */
export function sameValue(a, b) {
    if (a === b)
        return true;
    if (typeof a !== 'object' || typeof b !== 'object' || a === null || b === null)
        return Number.isNaN(a) && Number.isNaN(b);
    if (Array.isArray(a) !== Array.isArray(b))
        return false;
    const keys = Object.keys(a);
    if (keys.length !== Object.keys(b).length)
        return false;
    for (const key of keys) {
        if (!Object.hasOwn(b, key) || !sameValue(a[key], b[key]))
            return false;
    }
    return true;
}
