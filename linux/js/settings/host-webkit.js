// The host of the Settings page inside the GNOME settings window: a WebKit
// view whose program (`settings-app.js`) answers the page's messages and
// pushes the hub's state into it.
//
//   page → program   window.webkit.messageHandlers.capa.postMessage(JSON)
//                    {id, kind: 'call', module, method, args} | {id, kind: 'paste' | 'appNames', ids?}
//                    | {kind: 'ready' | 'painted' | 'background' | 'openUrl' | 'copy' | 'reveal' | 'pick' | 'scrolled' | 'close', ...}
//   program → page   window.__capaState(json, hint?)  the hub's state, whenever it changes; null while
//                                                there is no hub (capa-daemon is not running), and
//                                                then `hint`, `{language}`, the language last chosen
//                    window.__capaEvent(module, name, json)
//                    window.__capaReply(id, ok, json)

export function webkitHost() {
    let state = null, hint = null;
    const states = new Set(), events = new Set(), pending = new Map();
    let next = 0;
    let ready;
    const first = new Promise(resolve => { ready = resolve; });

    const post = message => window.webkit.messageHandlers.capa.postMessage(JSON.stringify(message));
    const ask = message => new Promise((resolve, reject) => {
        const id = ++next;
        pending.set(id, {resolve, reject});
        post({id, ...message});
    });

    // What goes wrong in the page is said where the program's own log is.
    window.addEventListener('error', e => post({kind: 'log', text: `${e.message} (${e.filename}:${e.lineno})`}));
    window.addEventListener('unhandledrejection', e => post({kind: 'log', text: `unhandled: ${e.reason?.stack ?? e.reason}`}));

    window.__capaState = (json, hinted) => {
        state = json === null || json === undefined || json === 'null' ? null : JSON.parse(json);
        hint = state === null && typeof hinted === 'string' && hinted ? JSON.parse(hinted) : null;
        ready();
        states.forEach(fn => fn());
    };
    window.__capaEvent = (module, name, json) => events.forEach(fn => fn(module, name, JSON.parse(json)));
    window.__capaReply = (id, ok, json) => {
        const waiting = pending.get(id);
        pending.delete(id);
        if (!waiting)
            return;
        if (ok)
            waiting.resolve(json === '' ? null : JSON.parse(json));
        else
            waiting.reject(new Error(json));
    };
    // The page asks for the state once it can take it. The program used to push it when the
    // view finished loading, which can come before this script has run — and then the page
    // waited, blank, for the next change of state.
    post({kind: 'ready'});

    // Go where the window is asked for again while open: `{section, module, page}`, each only if asked.
    window.__capaGo = target => window.dispatchEvent(new CustomEvent('capa-go', {detail: target}));

    return {
        platform: 'linux',
        nativeControls: false,
        ready: first,
        call: (module, method, args) => ask({kind: 'call', module, method, args: args ?? null}),
        state: () => state,
        /** What the program knows without a hub (`{language}`), while there is no state; null otherwise. */
        hint: () => hint,
        onState: fn => states.add(fn),
        onEvent: fn => events.add(fn),
        openUrl: url => post({kind: 'openUrl', url}),
        copyText: text => post({kind: 'copy', text}),
        revealPath: path => post({kind: 'reveal', path}),
        pickApplications: () => ask({kind: 'pick'}),
        /** A file shipped beside the extension (the page is its `settings/`), as a `file://` URI. */
        extensionFile: name => new URL(`../${name}`, location.href).href,
        // The clipboard as GTK has it: a `file://` page may be refused `navigator.clipboard`.
        readClipboard: () => ask({kind: 'paste'}),
        /** {id: name} for application identifiers, as the system names them. */
        applicationNames: ids => ask({kind: 'appNames', ids}),
        /** Whether the page is scrolled: the window's handle over the content's top steps aside then. */
        setScrolled: scrolled => post({kind: 'scrolled', scrolled}),
        // The first picture is drawn: the window may show (it waits, so nothing blank or white is ever seen).
        painted: () => post({kind: 'painted'}),
        setBackground: color => post({kind: 'background', color}),
        close: () => post({kind: 'close'}),
    };
}
