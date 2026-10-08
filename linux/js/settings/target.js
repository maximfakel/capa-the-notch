// Where "open Settings" goes, from what asked (`AppDelegate.showSettings`): a
// card's Connect and the strip's button go to Providers; the Teleprompter's
// Edit Script to the Modules section; Dictation's own (the capsule's "open
// Settings") to its card, on the setup page while the model or the microphone
// is not ready (`showSettings(forDictation:)`). Nothing asked — the menu's
// "Settings…" — asks for no section: a new window opens on General, one
// already open stays where it is.

export function settingsTarget(asked) {
    switch (asked) {
    case 'dictation': return {section: 'modules', module: 'dictation', page: 'auto'};
    case undefined:
    case null: return {};
    default: return {section: asked};
    }
}

/** The page's query string for a target: `section=modules&module=dictation&page=auto`. */
export function settingsQuery(asked) {
    return Object.entries(settingsTarget(asked)).map(([k, v]) => `${k}=${encodeURIComponent(v)}`).join('&');
}
