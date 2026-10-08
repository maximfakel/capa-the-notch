// The surface's words. English is the key itself, as in the Swift app's
// `L("...")`; Russian is a dictionary the daemon sends (`Localization`).

let dictionary = {};

/** `{ "Fresh": "Свежие", ... }` for the language in force; empty for English. */
export function setDictionary(entries) {
    dictionary = entries ?? {};
}

/** Looks a string up and fills `%@`, `%d` and `%%` in order, as `String(format:)` would. */
export function t(key, ...args) {
    const template = dictionary[key] ?? key;
    let n = 0;
    return template.replace(/%(?:(\d+)\$)?([@d%])/g, (match, position, kind) => {
        if (kind === '%')
            return '%';
        const value = args[position ? Number(position) - 1 : n++];
        return value === undefined ? match : String(value);
    });
}
