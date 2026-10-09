// Words and numbers in the person's own language and clock.

let locale = 'en-US';

/** `en` or `ru`, as Settings has it. */
export function setLanguage(code) {
    locale = code === 'ru' ? 'ru-RU' : 'en-US';
}

/** The desktop's 12 or 24 hours: true, false, or null to follow the language. */
let hour12 = null;

/** Whether the desktop's clock shows 12 hours (`clock-format`), or null for the language's own. */
export function setClockFormat(twelve) {
    hour12 = twelve == null ? null : !!twelve;
}

/**
 * The time of day, short, as the desktop's clock has it: `1:39 AM`, `01:39`.
 * What Swift formats in the system's own locale (`formatted(date: .omitted,
 * time: .shortened)`): the Shelf's clippings, Music's "played at".
 */
export function clock(unixSeconds) {
    const options = {hour: 'numeric', minute: '2-digit'};
    if (hour12 !== null)
        options.hour12 = hour12;
    return new Date(unixSeconds * 1000).toLocaleTimeString(locale, options);
}

/**
 * The time of day in the language's own clock, whatever the desktop's: English
 * `11:24 PM`, Russian `23:24`. What Swift formats in the app's language
 * (`.locale(Localization.current.locale)`): when a gauge's window comes back.
 */
export function languageClock(unixSeconds) {
    return new Date(unixSeconds * 1000).toLocaleTimeString(locale, {hour: 'numeric', minute: '2-digit'});
}

/** `5 Oct` — the day and the month, short, for "until …". */
export function dayMonth(unixSeconds) {
    return new Date(unixSeconds * 1000).toLocaleDateString(locale, {day: 'numeric', month: 'short'});
}
