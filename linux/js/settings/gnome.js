// The GNOME settings window's page: `?mode=onboarding` is the first-run
// window, `?section=` the section to open.

import {start, setSystemScheme} from './page.js';
import {webkitHost} from './host-webkit.js';

const params = new URLSearchParams(location.search);
// The program says which scheme GNOME is in; until the state names an appearance, the page wears it.
const scheme = params.get('scheme') ?? (window.matchMedia?.('(prefers-color-scheme: dark)').matches ? 'dark' : 'light');
document.documentElement.dataset.theme = scheme;
if (params.get('scheme'))
    setSystemScheme(scheme);
const host = webkitHost();
// The first state the program pushes, or null when no hub answers: the page then says capa-daemon
// is not running, in the language the program hints with it, and draws itself once a state comes.
await host.ready;

const window_ = start(document.getElementById('root'), host, {
    mode: params.get('mode') === 'onboarding' ? 'onboarding' : 'settings',
    section: params.get('section') ?? 'general',
    module: params.get('module') ?? 'music',
    page: params.get('page') ?? 'overview',
    step: Number(params.get('step') ?? 0),
});
window.addEventListener('capa-go', e => window_.go(e.detail ?? {}));
// GNOME's style changed while the window is open: "System" follows it.
window.addEventListener('capa-scheme', e => {
    setSystemScheme(e.detail);
    window_.schedule();
});
