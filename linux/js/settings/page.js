// The Settings and onboarding window, drawn from `schema.js` and the hub's
// state, in the GNOME settings window's WebKit; a `host` gives it the hub (`call`), the
// state, and the few things only the window's own program can do.
//
//   host.platform                 'linux'
//   host.call(module, method, args) -> Promise     a command for a Module (or 'hub')
//   host.state() / host.onState(fn) / host.onEvent(fn)
//   host.openUrl(url)  host.copyText(text)  host.revealPath(path)
//   host.pickApplications() -> Promise<string[]>   identifiers of chosen applications
//   host.close()

import {
    CONSENT, DICTATION_PAGES, MODULES, MODULE_SWITCH, MUSIC_NOTE, ONBOARDING_STEPS, SECTIONS, SHELF_IMAGES,
    SHELF_NOTE, SHELF_TEXT, accessRows, blocksFor, clippingLimitOptions, dictationRows, get, providerNote,
    providerStatus, refreshLabel, settingsOf, teleprompterRows,
} from './schema.js';
import {
    animate, button, carry, closeMenu, dialog, glyph, h, icon, iconButton, isMenuOpen, keycaps, mark, noteSwitches, onMenuClose,
    picker, reduced, springMotion, toggleSwitch,
} from './dom.js';
import {CHANGE, REDUCED, UNFOLD} from './motion.js';
import {setDictionary, t as rawT} from '../ui/strings.js';
import {setLanguage} from '../ui/format.js';
import {EXTRA_RU} from './strings-extra.js';

/** The system the window is on: words the Swift wrote about the Mac are said of it. */
let platform = 'linux';
/** The language the hub says the window speaks ('en' | 'ru'), not guessed from the words. */
let language = 'en';
/** The system's own scheme as the program reads it from GNOME ('dark' | 'light'), when it says; else the web view's. */
let systemScheme = null;
export function setSystemScheme(scheme) {
    systemScheme = scheme === 'dark' || scheme === 'light' ? scheme : null;
}

/** Where a sentence starts: the text's start, or after a full stop. */
const START = '(^|[.!?]\\s+)';

const SAY = {
    en: {
        linux: [[/this Mac/g, 'this computer'], [/Finder/g, 'Files'], [/System Settings/g, "the system's settings"],
            [new RegExp(`${START}macOS`, 'g'), '$1The system'], [/macOS/g, 'the system']],
    },
    ru: {
        linux: [[/этом Mac/g, 'этом компьютере'], [/спросит macOS/g, 'спросит система'], [/Показать в Finder/g, 'Показать в «Файлах»'],
            [/в Finder/g, 'в «Файлах»'], [/Finder/g, '«Файлы»'], [/в Системных настройках/g, 'в настройках системы'],
            [new RegExp(`${START}macOS`, 'g'), '$1Система'], [/macOS/g, 'система']],
    },
};

/** `t()`, then said for this system. */
function t(key, ...args) {
    const said = rawT(key, ...args);
    return (SAY[language === 'ru' ? 'ru' : 'en'][platform] ?? []).reduce((text, [from, to]) => text.replace(from, to), said);
}

/** `SettingsMotion.change`: a section or step changing, and what changes with it; `.easeInOut(duration: 0.15)` under Reduce Motion. */
const changeMotion = () => (reduced() ? REDUCED : CHANGE);

/**
 * The language the window speaks: the hub's, or without a hub the one the program
 * says was last chosen (`host.hint()`), so "capa-daemon is not running" is said in it.
 */
export function spokenLanguage(host) {
    return host.state()?.language ?? host.hint?.()?.language ?? 'en';
}

export function start(root, host, {mode = 'settings', section = 'general', module = 'music', page = 'overview', step = 0} = {}) {
    platform = host.platform ?? 'linux';
    language = spokenLanguage(host) === 'ru' ? 'ru' : 'en';
    const window_ = new Window(root, host, mode, section);
    window_.expandedModule = module;
    window_.dictationPage = window_.resolvePage(page);
    window_.step = window_.reached = Math.min(Math.max(step, 0), ONBOARDING_STEPS.length - 1);
    // The window opens on where it was asked to: nothing changes as it appears.
    window_.instant = true;
    window_.render();
    return window_;
}

class Window {
    constructor(root, host, mode, section) {
        this.root = root;
        this.host = host;
        this.mode = mode;
        this.section = SECTIONS.some(s => s.id === section) ? section : 'general';
        this.expandedModule = 'music';
        this.dictationPage = 'overview';
        this.step = 0;
        this.reached = 0;
        this.report = null;
        this.pending = false;
        this.renderTimer = 0;
        this.hoverTimer = 0;
        /** A key pressed in the Modules: no card opens under a resting pointer until the next click (`ModulesSection`). */
        this.keyboardLock = false;
        /** Application identifiers the system has named, for the Shelf's excluded applications. */
        this.appNames = {};
        /** Motions still running when the page is drawn again, carried on by what is drawn in their place. */
        this.motions = [];
        /** What is faded out where it stood (a page left, a card's content folded away), kept across a redraw. */
        this.ghosts = [];
        /** Where the pointer is, while it is over the window. */
        this.pointer = null;

        document.body.classList.toggle('native-controls', !!host.nativeControls);
        host.onState(() => this.schedule());
        window.addEventListener('keydown', e => this.key(e));
        window.addEventListener('pointerdown', e => {
            this.keyboardLock = false;
            this.pointer = [e.clientX, e.clientY];
        }, true);
        // Once the pointer moves the web view knows again what is under it.
        window.addEventListener('pointermove', e => {
            this.pointer = [e.clientX, e.clientY];
            this.unmarkHover();
        }, true);
        document.documentElement.addEventListener('pointerleave', () => {
            this.pointer = null;
            this.unmarkHover();
        });
        document.addEventListener('focusout', () => setTimeout(() => this.pending && this.schedule(), 0));
        onMenuClose(() => this.pending && this.schedule());
        // "System" follows the system's appearance as it changes.
        window.matchMedia?.('(prefers-color-scheme: dark)').addEventListener?.('change', () => this.schedule());
        // "read 2 minutes ago" keeps telling the truth while the window stays open.
        setInterval(() => this.schedule(), 30_000);
        this.render();
    }

    get state() { return this.host.state(); }
    get s() { return settingsOf(this.state); }

    /** Dictation asked for ('auto'): set up first, while the model or the microphone is not ready. */
    resolvePage(page) {
        if (page !== 'auto')
            return DICTATION_PAGES[page] ? page : 'overview';
        const d = this.state?.modules?.dictation ?? {};
        return d.modelReady && d.microphoneAllowed !== false ? 'overview' : 'setup';
    }

    /**
     * What a field being typed in, or a menu being read, must not lose: no
     * redraw under an insertion point or an open menu; it comes once they are done.
     */
    schedule() {
        const editing = document.activeElement?.matches?.('textarea, input[type=text]');
        if (editing || isMenuOpen()) {
            this.pending = true;
            return;
        }
        this.pending = false;
        cancelAnimationFrame(this.renderTimer);
        this.renderTimer = requestAnimationFrame(() => this.render());
    }

    /**
     * The hub sends no state that is the one it last sent: a value it kept as it
     * was (clamped, or the same) brings none, so the window is drawn again from
     * the state it has, never left showing what was typed or clicked.
     */
    async set(key, value) {
        try {
            await this.host.call('settings', 'set', {key, value});
        } catch (e) {
            console.error(`${key}: ${e.message ?? e}`);
        }
        this.schedule();
    }

    async command(command, args = null) {
        try {
            return await this.host.call('settings', command, args);
        } catch (e) {
            console.error(`${command}: ${e.message ?? e}`);
            return undefined;
        } finally {
            this.schedule();
        }
    }

    // MARK: - The window

    render() {
        this.pending = false;
        closeMenu();
        const state = this.state;
        const s = this.s;
        const said = spokenLanguage(this.host);
        language = said === 'ru' ? 'ru' : 'en';
        // Focus comes back to the same control in the new page, found by its key.
        const focused = this.root.contains(document.activeElement) ? document.activeElement?.dataset?.key : null;
        document.documentElement.dataset.theme = this.theme(s);
        // The program paints what lies behind the page (the view's own background, the window's
        // corners) in the page's colour: a different one shows as a strip where the page stops short.
        this.host.setBackground?.(getComputedStyle(document.body).backgroundColor);
        if (state?.dictionary) {
            setDictionary({...state.dictionary, ...(said === 'ru' ? EXTRA_RU : {})});
        } else {
            // No hub: its words are not here, and what the page says without one is in ours.
            setDictionary(said === 'ru' ? EXTRA_RU : {});
        }
        setLanguage(said);
        document.documentElement.lang = said;

        // The scroll view keeps its offset whatever it shows, as SwiftUI's does: a new section or
        // step, or Dictation's pages, are shown from there, clamped to what they have.
        const top = this.root.querySelector('.scroll')?.scrollTop ?? 0;
        const view = `${this.mode}:${this.section}:${this.step}`;
        const samePage = this.rendered === `${view}:${this.dictationPage}`;
        // A section or step chosen in the window changes on `SettingsMotion.change`; one asked for
        // from outside, a window opening, and Dictation's pages are simply there (none of them is
        // in an animated transaction in the Swift).
        const changing = !this.instant && !!this.renderedView && this.renderedView !== view;
        this.instant = false;
        // A header gone takes its hover's wait with it (`onDisappear`); one drawn again keeps it.
        if (!samePage)
            clearTimeout(this.hoverTimer);
        const before = samePage || changing ? this.snapshot() : null;
        noteSwitches(this.root, samePage);
        const running = this.keepMotions(samePage);
        this.root.replaceChildren();
        if (!s) {
            this.rendered = this.renderedView = null;
            this.root.append(h('div', {class: 'hubless', text: t('capa-daemon is not running. Start it, then reopen Settings.')}));
            this.drawn();
            return;
        }
        this.rendered = `${view}:${this.dictationPage}`;
        this.renderedView = view;
        this.renderedExpanded = this.expandedModule;
        // Nothing drawn anew starts a transition of its own: a row under the pointer is lit as it was.
        this.root.classList.add('still');
        const main = h('div', {class: 'main'});
        const page = this.mode === 'onboarding' ? this.onboardingPage(state, s) : this.settingsPage(state, s);
        const scroller = h('div', {class: 'scroll'}, page);
        main.append(scroller);
        if (this.mode === 'onboarding')
            main.append(this.footer(s));
        const app = h('div', {class: 'app'},
            // The window is moved by its top edge: always over the sidebar, over the content only
            // while nothing has scrolled under it, so a scrolled control is never covered.
            h('div', {class: 'drag side'}),
            h('div', {class: 'drag top'}),
            h('button', {class: 'close', 'aria-label': t('Close'), onClick: () => this.host.close()}, icon('close', 1)),
            this.mode === 'onboarding' ? this.onboardingSidebar(s) : this.sidebar(),
            main);
        this.root.append(app);
        const scrolled = () => {
            const on = scroller.scrollTop > 0;
            if (on !== this.scrolled) {
                this.scrolled = on;
                this.host.setScrolled?.(on);
            }
            app.classList.toggle('scrolled', on);
        };
        scroller.addEventListener('scroll', scrolled, {passive: true});
        scroller.scrollTop = top;
        scrolled();
        if (focused)
            this.root.querySelector(`[data-key="${CSS.escape(focused)}"]`)?.focus({preventScroll: true});
        this.markHover();
        void this.root.offsetHeight;
        this.root.classList.remove('still');

        this.drawn();
        this.placeHighlight(app);
        this.resume(running);
        if (changing) {
            this.sidebarChange(app, before);
            this.pageChange(scroller, before);
            if (this.mode === 'onboarding')
                this.footerChange(main.querySelector('.footer'), before);
        } else if (samePage) {
            this.appear(before);
            if (before.expanded !== this.expandedModule)
                this.unfold(before);
        }
    }

    /**
     * The page is drawn for the first time: the window may show. Said at once, not after a frame:
     * a WebKit view draws no frame while its window is not on screen, so waiting for one kept the
     * window back until the program gave up waiting (1.5 s).
     */
    drawn() {
        if (this.painted)
            return;
        this.painted = true;
        this.host.painted?.();
    }

    // MARK: - Motion

    /**
     * What moves from where it was drawn: the sidebar, the page and the footer as they stand,
     * the Module cards' heights and what each holds, the groups shown.
     */
    snapshot() {
        const r = this.root;
        const at = el => ({top: el.offsetTop, left: el.offsetLeft, width: el.offsetWidth});
        const live = el => !el.inert;
        const page = r.querySelector('.scroll > .page');
        const look = page && getComputedStyle(page);
        return {
            highlight: this.highlightAt(),
            items: [...r.querySelectorAll('.sidebar .side-item')].map(el => ({
                selected: el.classList.contains('selected'), opacity: getComputedStyle(el).opacity,
                background: getComputedStyle(el).backgroundColor,
                marker: el.querySelector('.keycap')?.firstChild?.nodeValue ?? null,
                markerColor: el.querySelector('.keycap') ? getComputedStyle(el.querySelector('.keycap')).color : null,
            })),
            page, pageLook: look ? {opacity: look.opacity, transform: look.transform} : null,
            cards: new Map([...r.querySelectorAll('.scroll .card[data-module]')].map(c => {
                const content = [...c.children].slice(1).filter(live);
                return [c.dataset.module, {height: c.getBoundingClientRect().height, content, at: content[0] ? at(content[0]) : null}];
            })),
            expanded: this.renderedExpanded,
            shown: new Map([...r.querySelectorAll('.scroll [data-appear]')].filter(live).map(e => [e.dataset.appear, {node: e, ...at(e)}])),
            footer: new Map([...r.querySelectorAll('.footer .btn')].filter(live).map(b => [b.dataset.key, {
                node: b, label: b.firstChild?.nodeValue ?? '', opacity: getComputedStyle(b).opacity, color: getComputedStyle(b).color, ...at(b),
            }])),
        };
    }

    /** Runs `keyframes` on `el`; drawn again before they end, what `find` finds in its place carries on. */
    play(el, keyframes, timing, find) {
        const motion = animate(el, keyframes, timing);
        this.motions.push({motion, keyframes, timing, find});
        return motion;
    }

    /**
     * Fades what is gone where it stood (`place` puts it there, again after a redraw), as SwiftUI
     * draws a removed view until its transition ends; `target` is what moves, `lasts` keeps it
     * through a change of section (a page left behind).
     */
    ghost(node, keyframes, timing, place, {target = node, lasts = false} = {}) {
        node.inert = true;
        node.setAttribute('aria-hidden', 'true');
        node.style.pointerEvents = 'none';
        if (!place(this.root, node))
            return;
        const g = {node, place, lasts, motion: animate(target, keyframes, {...timing, fill: 'forwards'})};
        this.ghosts.push(g);
        g.motion.finished.then(() => {
            node.remove();
            this.ghosts = this.ghosts.filter(x => x !== g);
        }, () => {});
    }

    /** Before a redraw: the motions still running and how far each has gone; on a new page only pages left behind go on. */
    keepMotions(samePage) {
        const kept = samePage
            ? this.motions.filter(m => m.motion.playState === 'running').map(m => ({...m, start: m.motion.startTime, time: m.motion.currentTime}))
            : [];
        this.motions = [];
        for (const g of this.ghosts) {
            if (!samePage && !g.lasts) {
                g.motion.cancel();
                g.node.remove();
            }
        }
        this.ghosts = this.ghosts.filter(g => samePage || g.lasts);
        return kept;
    }

    /** After a redraw: each motion carries on in what took its element's place, each ghost where it stood. */
    resume(kept) {
        for (const m of kept) {
            const el = m.find(this.root);
            if (!el)
                continue;
            this.motions.push({...m, motion: carry(animate(el, m.keyframes, m.timing), m)});
        }
        this.ghosts = this.ghosts.filter(g => {
            if (g.place(this.root, g.node))
                return true;
            g.motion.cancel();
            return false;
        });
    }

    /**
     * What was under the pointer still is: drawn anew, a row is lit as it was rather than
     * dark until the web view looks again, then lit on the hover's ease.
     */
    markHover() {
        if (!this.pointer)
            return;
        for (let el = document.elementFromPoint(...this.pointer); el && el !== this.root; el = el.parentElement)
            el.classList.add('hovered');
        this.hoverMarked = true;
    }

    unmarkHover() {
        if (!this.hoverMarked)
            return;
        this.hoverMarked = false;
        this.root.querySelectorAll('.hovered').forEach(el => el.classList.remove('hovered'));
    }

    /** Where the sidebar's highlight stands now, mid-slide if it is sliding. */
    highlightAt() {
        const highlight = this.root.querySelector('.sidebar > .highlight');
        if (!highlight || highlight.hidden)
            return null;
        const transform = getComputedStyle(highlight).transform;
        return !transform || transform === 'none' ? 0 : new DOMMatrixReadOnly(transform).m42;
    }

    placeHighlight(app) {
        const highlight = app.querySelector('.sidebar > .highlight');
        const item = app.querySelector('.sidebar .side-item.selected');
        if (!highlight)
            return;
        if (!item)
            highlight.hidden = true;
        else
            highlight.style.transform = `translateY(${item.offsetTop}px)`;
    }

    /**
     * A changed text drawn anew over the old one, each fading (SwiftUI's default content
     * transition): `was` dresses the old one's copy, `color` is the colour it was in.
     */
    crossfade(el, was, color, timing, find) {
        const host = el?.offsetParent;
        if (!host)
            return;
        const ghost = el.cloneNode(true);
        Object.assign(ghost.style, {
            position: 'absolute', left: `${el.offsetLeft}px`, top: `${el.offsetTop}px`, width: `${el.offsetWidth}px`,
            height: `${el.offsetHeight}px`, margin: '0', boxSizing: 'border-box',
        });
        was(ghost);
        this.play(el, [{color: 'transparent'}, {color: getComputedStyle(el).color}], timing, find);
        this.ghost(ghost, [{color}, {color: 'transparent'}], timing, (r, n) => {
            const p = find(r)?.offsetParent;
            p?.append(n);
            return !!p;
        });
    }

    /**
     * The sidebar on `SettingsMotion.spring`, as a section or step changes: one highlight going and
     * one coming, moved together between the items, each on its own fade (`matchedGeometryEffect`,
     * and the default `.opacity` transition of each); the icon's colour, the title's weight and a
     * step's marker drawn anew and crossfaded; a line lit under the pointer fading as it is chosen
     * (or lit as it is left); a step coming within reach.
     */
    sidebarChange(app, before) {
        const timing = springMotion();
        const items = [...app.querySelectorAll('.sidebar .side-item')];
        const highlight = app.querySelector('.sidebar > .highlight');
        const item = items.find(el => el.classList.contains('selected'));
        const findHighlight = r => r.querySelector('.sidebar > .highlight');
        if (highlight && item && before.highlight !== null && Math.abs(before.highlight - item.offsetTop) > 0.5) {
            const move = [`translateY(${before.highlight}px)`, `translateY(${item.offsetTop}px)`];
            this.play(highlight, [{transform: move[0], opacity: 0}, {transform: move[1], opacity: 1}], timing, findHighlight);
            this.ghost(highlight.cloneNode(), [{transform: move[0], opacity: 1}, {transform: move[1], opacity: 0}], timing, (r, n) => {
                const real = findHighlight(r);
                real?.after(n);
                return !!real;
            });
        }
        const colour = name => getComputedStyle(document.documentElement).getPropertyValue(name).trim();
        items.forEach((el, i) => {
            const was = before.items[i];
            if (!was)
                return;
            const find = selector => r => {
                const counterpart = r.querySelectorAll('.sidebar .side-item')[i];
                return selector ? counterpart?.querySelector(selector) : counterpart;
            };
            if (was.selected !== el.classList.contains('selected')) {
                this.crossfade(el.querySelector('.icon'), () => {}, colour(was.selected ? '--text' : '--icon'), timing, find('.icon'));
                this.crossfade(el.querySelector('.title'), g => { g.style.fontWeight = was.selected ? '500' : '400'; },
                    getComputedStyle(el.querySelector('.title')).color, timing, find('.title'));
            }
            const marker = el.querySelector('.keycap');
            if (marker && was.marker !== null && was.marker !== marker.firstChild?.nodeValue)
                this.crossfade(marker, g => {
                    g.textContent = was.marker;
                    g.style.background = 'none';
                }, was.markerColor, timing, find('.keycap'));
            const now = getComputedStyle(el);
            const changed = {};
            if (was.opacity !== now.opacity)
                changed.opacity = [was.opacity, now.opacity];
            if (was.background !== now.backgroundColor)
                changed.backgroundColor = [was.background, now.backgroundColor];
            if (Object.keys(changed).length) {
                this.play(el, [0, 1].map(k => Object.fromEntries(Object.entries(changed).map(([p, v]) => [p, v[k]]))), timing, find(null));
            }
        });
    }

    /**
     * A new section or step (`.transition(.opacity.combined(with: .offset(y: 6)))`): it comes in
     * from 6 points below as the one left goes 6 points down, both fading, at once, on one
     * spring; the one left stays where it stood in the scroll view until it is gone. Under Reduce
     * Motion both only fade.
     */
    pageChange(scroller, before) {
        const timing = changeMotion();
        const rise = !reduced();
        const findPage = r => r.querySelector('.scroll > .page');
        this.play(scroller.firstElementChild, rise
            ? [{opacity: 0, transform: 'translateY(6px)'}, {opacity: 1, transform: 'none'}]
            : [{opacity: 0}, {opacity: 1}], timing, findPage);
        const old = before.page;
        if (!old)
            return;
        // From wherever it stood, if it was still coming in.
        const {opacity, transform} = before.pageLook;
        old.getAnimations().forEach(a => a.cancel());
        Object.assign(old.style, {position: 'absolute', left: '0', right: '0'});
        const from = transform === 'none' ? 'translateY(0px)' : transform;
        const fall = rise ? 'translateY(6px)' : from;
        this.ghost(h('div', {class: 'leaving'}, old), [{opacity, transform: from}, {opacity: 0, transform: fall}], timing, (r, n) => {
            const main = r.querySelector('.main');
            const view = main?.querySelector('.scroll');
            if (!view)
                return false;
            main.prepend(n);
            n.style.height = `${view.clientHeight}px`;
            const follow = () => { n.firstElementChild.style.top = `${-view.scrollTop}px`; };
            follow();
            view.addEventListener('scroll', follow, {passive: true});
            return true;
        }, {target: old, lasts: true});
    }

    /**
     * Onboarding's footer as the step changes, on the same motion: a button that comes fades in,
     * one that goes fades out where it stood, Continue's title becoming Finish crossfades as its
     * width follows, and its being enabled fades.
     */
    footerChange(footer, before) {
        if (!footer)
            return;
        const timing = changeMotion();
        const now = new Map([...footer.querySelectorAll('.btn')].map(b => [b.dataset.key, b]));
        for (const [key, b] of now) {
            const find = r => r.querySelector(`.footer .btn[data-key="${CSS.escape(key)}"]`);
            const was = before.footer.get(key);
            const opacity = getComputedStyle(b).opacity;
            if (!was) {
                this.play(b, [{opacity: 0}, {opacity}], timing, find);
                continue;
            }
            if (was.opacity !== opacity)
                this.play(b, [{opacity: was.opacity}, {opacity}], timing, find);
            if (was.label !== b.firstChild?.nodeValue) {
                this.play(b, [{width: `${was.width}px`}, {width: `${b.offsetWidth}px`}], timing, find);
                const label = h('span', {class: 'label-gone', text: was.label});
                this.play(b, [{color: 'transparent'}, {color: getComputedStyle(b).color}], timing, find);
                this.ghost(label, [{color: was.color}, {color: 'transparent'}], timing, (r, n) => {
                    const counterpart = find(r);
                    counterpart?.append(n);
                    return !!counterpart;
                });
            }
        }
        for (const [key, was] of before.footer) {
            if (now.has(key))
                continue;
            Object.assign(was.node.style, {position: 'absolute', left: `${was.left}px`, top: `${was.top}px`, margin: '0'});
            this.ghost(was.node, [{opacity: was.opacity}, {opacity: 0}], timing, (r, n) => {
                const f = r.querySelector('.footer');
                f?.append(n);
                return !!f;
            });
        }
    }

    /**
     * A group shown or hidden as the state changes, on `SettingsMotion.change`: only the one the
     * Swift animates (`.animation(_:value: providerAnswered)`), which fades in, or out where it stood.
     */
    appear(before) {
        const timing = changeMotion();
        const now = new Map([...this.root.querySelectorAll('.scroll [data-appear]')].map(e => [e.dataset.appear, e]));
        for (const [key, el] of now) {
            if (!before.shown.has(key))
                this.play(el, [{opacity: 0}, {opacity: 1}], timing, r => r.querySelector(`.scroll [data-appear="${key}"]`));
        }
        for (const [key, was] of before.shown) {
            if (now.has(key))
                continue;
            Object.assign(was.node.style, {position: 'absolute', left: `${was.left}px`, top: `${was.top}px`, width: `${was.width}px`});
            this.ghost(was.node, [{opacity: 1}, {opacity: 0}], timing, (r, n) => {
                const p = r.querySelector('.scroll > .page');
                p?.append(n);
                return !!p;
            });
        }
    }

    /**
     * A Module card opening (`ModulesSection.expand`, `.timingCurve(0.23, 1, 0.32, 1, duration: 0.2)`):
     * each card's height follows, the one opening shows what it holds fading in (the default
     * `.opacity`), unclipped, and the one closing fades what it held where it stood. Under Reduce
     * Motion it is simply open.
     */
    unfold(before) {
        if (reduced())
            return;
        for (const card of this.root.querySelectorAll('.scroll .card[data-module]')) {
            const id = card.dataset.module;
            const find = r => r.querySelector(`.scroll .card[data-module="${id}"]`);
            const was = before.cards.get(id);
            if (!was)
                continue;
            const to = card.getBoundingClientRect().height;
            if (Math.abs(was.height - to) >= 0.5)
                this.play(card, [{height: `${was.height}px`}, {height: `${to}px`}], UNFOLD, find);
            if (id === this.expandedModule) {
                [...card.children].slice(1).forEach((el, i) =>
                    this.play(el, [{opacity: 0}, {opacity: 1}], UNFOLD, r => find(r)?.children[i + 1]));
            } else if (id === before.expanded && was.content.length) {
                const folded = h('div', {class: 'folded', style: {top: `${was.at.top}px`, left: `${was.at.left}px`, width: `${was.at.width}px`}},
                    was.content);
                this.ghost(folded, [{opacity: 1}, {opacity: 0}], UNFOLD, (r, n) => {
                    const counterpart = find(r);
                    counterpart?.append(n);
                    return !!counterpart;
                });
            }
        }
    }

    theme(s) {
        const choice = s?.appearance ?? 'system';
        if (choice === 'light' || choice === 'dark')
            return choice;
        return systemScheme ?? (window.matchMedia?.('(prefers-color-scheme: dark)').matches ? 'dark' : 'light');
    }

    /**
     * The window's keys, as the Swift has them: Ctrl+1–5 for the sections, the
     * arrows while the sidebar has focus, Return for Continue in onboarding.
     * Escape closes nothing here (the Swift window has no such key): an open
     * menu and the consent dialog take it for themselves.
     */
    key(e) {
        if (this.mode === 'settings' && this.section === 'modules')
            this.keyboardLock = true;
        if (e.defaultPrevented || this.recording || isMenuOpen() || document.querySelector('.scrim'))
            return;
        if (this.mode === 'settings' && (e.ctrlKey || e.metaKey) && /^[1-5]$/.test(e.key)) {
            this.go(SECTIONS[Number(e.key) - 1].id);
            e.preventDefault();
        } else if (this.mode === 'settings' && (e.key === 'ArrowDown' || e.key === 'ArrowUp') && e.target.closest?.('.sidebar')) {
            const i = SECTIONS.findIndex(x => x.id === this.section) + (e.key === 'ArrowDown' ? 1 : -1);
            if (SECTIONS[i])
                this.go(SECTIONS[i].id);
            e.preventDefault();
        } else if (this.mode === 'onboarding' && e.key === 'Enter' && !e.altKey && !e.ctrlKey && !e.metaKey && !e.shiftKey
            && !e.target.matches?.('input, textarea, button, [role=switch], [contenteditable]')) {
            // `.keyboardShortcut(.defaultAction)` on Continue and Finish.
            const goOn = this.root.querySelector('.footer .btn.prominent');
            if (goOn && !goOn.disabled) {
                e.preventDefault();
                goOn.click();
            }
        }
    }

    /** A section from the sidebar or the keys; or, asked from outside, `{section, module, page}`. */
    go(target) {
        if (typeof target === 'string') {
            // Dictation's page stays where it was, for when Modules is chosen again.
            this.section = target;
            this.render();
            return;
        }
        // Asked from outside, the window is shown where it was asked to be, at once: the Swift sets
        // it outside any animation (`showSettings`).
        this.instant = true;
        const {section, module, page} = target ?? {};
        if (!section)
            return;
        if (SECTIONS.some(s => s.id === section))
            this.section = section;
        if (module && MODULE_SWITCH[module])
            this.expandedModule = module;
        this.dictationPage = page ? this.resolvePage(page) : 'overview';
        this.render();
    }

    // MARK: - Sidebar (settings)

    sidebar() {
        // The sidebar takes focus as a whole, and the arrows move between its sections (`onMoveCommand`).
        return h('div', {class: 'sidebar', role: 'tablist', tabindex: '0', 'data-key': 'sidebar', 'aria-label': t('Settings sections')},
            h('div', {class: 'highlight', 'aria-hidden': 'true'}),
            SECTIONS.map((section, i) =>
                h('button', {
                    class: `side-item${section.id === this.section ? ' selected' : ''}`, role: 'tab', tabindex: '-1',
                    'data-key': `section:${section.id}`,
                    'aria-selected': String(section.id === this.section), onClick: () => this.go(section.id),
                }, icon(section.icon, 1), h('span', {class: 'title', text: t(section.title)}),
                keycaps([this.host.platform === 'linux' ? 'Ctrl' : '⌘', String(i + 1)]))));
    }

    settingsPage(state, s) {
        if (this.section === 'modules' && this.dictationPage !== 'overview')
            return h('div', {class: 'page compact-top'}, this.dictationSubpage(state, s));
        const def = SECTIONS.find(x => x.id === this.section);
        const page = h('div', {class: 'page'});
        if (this.section !== 'modules')
            page.append(this.heading(def.title, def.subtitle));
        if (this.section === 'modules')
            page.append(...this.modulesPage(state, s));
        else
            page.append(...this.blocks(blocksFor(this.section, state, s), state, s));
        return page;
    }

    heading(title, subtitle) {
        return h('div', {class: 'heading'}, h('h1', {text: t(title), role: 'heading'}), h('p', {text: t(subtitle)}));
    }

    // MARK: - Blocks

    blocks(blocks, state, s) {
        return blocks.map(block => {
            switch (block.kind) {
            case 'group': return this.group(block, state, s);
            case 'providers': return this.providerCards(state, s);
            default: return h('div');
            }
        });
    }

    group(block, state, s) {
        const card = h('div', {class: 'card'}, block.rows.map(row => this.row(row, state, s)));
        return h('div', {class: 'group'}, card, block.footnote
            ? h('div', {class: 'footnote', text: this.footnote(block.footnote)}) : null);
    }

    /** The one sentence the Swift writes about macOS, said of the system it is on. */
    footnote(text) {
        return t(text);
    }

    row(row, state, s) {
        switch (row.kind) {
        case 'divider': return h('div', {class: 'divider'});
        case 'toggle': return this.toggleRow(row, s);
        case 'picker': return this.pickerRow(row, s);
        case 'version': return this.versionRow(row, s);
        case 'actions': return this.actionsRow(row);
        case 'report': return this.report ? h('div', {class: 'report', text: this.report}) : h('div');
        default: return h('div');
        }
    }

    toggleRow(row, s) {
        const on = !!get(s, row.path);
        const writes = value => (row.keyPrefix ? this.set(`${row.keyPrefix}.${row.provider}`, value) : this.set(row.key, value));
        const title = row.literal ? row.title : t(row.title);
        const el = h('div', {class: `row hovers toggle-row${row.disabled ? ' disabled' : ''}`, style: {paddingLeft: `${10 + (row.indent ?? 0)}px`}},
            h('span', {class: 'label', text: title}),
            toggleSwitch(on, {disabled: row.disabled, label: title, onToggle: writes, focusKey: `toggle:${row.key ?? `${row.keyPrefix}.${row.provider}`}`}));
        el.addEventListener('click', () => { if (!row.disabled) el.querySelector('.switch').click(); });
        return el;
    }

    pickerRow(row, s) {
        const value = get(s, row.path);
        const current = row.options.find(o => o.id === value) ?? row.options[0];
        return h('div', {class: 'row hovers'}, h('span', {class: 'label', text: t(row.title)}),
            picker({label: current?.title ?? '', options: row.options, value, onPick: id => this.set(row.key, id), focusKey: `picker:${row.key}`}));
    }

    versionRow(row, s) {
        return h('div', {class: 'row hovers'},
            h('span', {style: {display: 'flex', alignItems: 'baseline', gap: '8px', flex: 1}},
                h('span', {text: row.name}), h('span', {class: 'caption', text: t('Version %@', get(s, row.path))})),
            button(t(row.button.title), {onClick: async () => {
                const answer = await this.command(row.button.command);
                if (answer?.url)
                    this.host.openUrl(answer.url);
            }}));
    }

    actionsRow(row) {
        const make = b => button(t(b.title), {disabled: b.disabled, onClick: () => this.action(b)});
        return h('div', {class: 'row', style: {minHeight: `${row.height}px`}},
            row.left.map(make), h('span', {class: 'grow'}), row.right.map(make));
    }

    async action(b) {
        if (b.command) {
            await this.command(b.command);
            return;
        }
        if (b.action === 'copyDiagnostics') {
            try {
                const report = await this.host.call('hub', 'diagnosticReport', null);
                this.host.copyText(report);
                this.report = report;
                this.render();
            } catch (e) {
                console.error(e);
            }
        } else if (b.action === 'revealLog') {
            const info = await this.command('diagnosticsInfo');
            if (info?.logPath)
                this.host.revealPath(info.logPath);
        } else if (b.action === 'pasteScript') {
            try {
                // Through the window's program where it can: a `file://` page may be refused the clipboard.
                const text = await (this.host.readClipboard ? this.host.readClipboard() : navigator.clipboard.readText());
                // Nothing to read is no Script: the one there stays (`pasteFromClipboard`).
                if (typeof text === 'string' && text.trim() !== '')
                    await this.command('replaceScript', {text});
            } catch (e) {
                console.error(`the clipboard could not be read: ${e}`);
            }
        }
    }

    // MARK: - Providers

    providerCards(state, s) {
        // Now as the window reads it, redrawn every 30 seconds (`TimelineView(.periodic(by: 30))`).
        const now = Math.floor(Date.now() / 1000);
        const views = new Map((state.providers ?? []).map(p => [p.provider, p]));
        return h('div', {class: 'stack'}, s.providers.map(p => this.providerCard(p, views.get(p.provider), now)));
    }

    providerCard(p, view, now) {
        const status = providerStatus(p.on, view, now, {ago: (at, n) => this.ago(at, n), clock: at => this.clock(at)});
        const note = providerNote(p.on, p.canConnect, view);
        const toggle = toggleSwitch(p.on, {disabled: !p.on && !p.canConnect, label: p.name, onToggle: on => this.setProvider(p, on), focusKey: `provider:${p.provider}`});
        return h('div', {class: 'card'},
            h('div', {class: 'row hovers provider'},
                mark(p.provider, 18),
                h('div', {class: 'who'},
                    h('span', {class: 'name', text: p.name}),
                    h('span', {class: 'status'}, h('i', {class: `dot ${status.tint}`}), status.line)),
                iconButton('refresh', t('Refresh %@', p.name), () => this.host.call('hub', 'refresh', {provider: p.provider}).catch(() => {}),
                    {disabled: !p.on, focusKey: `refresh:${p.provider}`}),
                toggle),
            note ? h('div', {class: 'provider-note', text: note}) : null);
    }

    /** Past the two-at-most rule the switch stays off; before consent the question is asked first. */
    async setProvider(p, on) {
        if (on && p.needsConsent) {
            const text = CONSENT[p.provider];
            const agreed = await dialog({title: t(text.title), body: t(text.body), ok: t('Turn On'), cancel: t('Cancel')});
            if (!agreed) {
                this.schedule();
                return;
            }
            await this.command('giveConsent', {provider: p.provider});
        }
        await this.command('setProvider', {provider: p.provider, on});
    }

    /** `RelativeDateTimeFormatter`: the largest whole unit, "2 minutes ago"; Russian short, "2 мин. назад". */
    ago(at, now) {
        const seconds = now - at;
        if (seconds < 60)
            return t('just now');
        const ru = language === 'ru';
        const rtf = new Intl.RelativeTimeFormat(ru ? 'ru' : 'en', {numeric: 'always', style: ru ? 'short' : 'long'});
        const units = [['year', 365 * 86400], ['month', 30 * 86400], ['week', 7 * 86400], ['day', 86400], ['hour', 3600], ['minute', 60]];
        const [unit, size] = units.find(([, size]) => seconds >= size);
        return rtf.format(-Math.floor(seconds / size), unit);
    }

    clock(at) {
        return new Date(at * 1000).toLocaleTimeString(language === 'ru' ? 'ru-RU' : 'en-US', {hour: 'numeric', minute: '2-digit'});
    }

    // MARK: - Modules

    modulesPage(state, s) {
        return [
            h('div', {class: 'heading plain'}, h('h1', {text: t('Modules')}), h('p', {text: t('Built-in features. Each one is off until you turn it on.')})),
            h('div', {class: 'stack', style: {gap: '8px'}}, MODULES.map(m => this.moduleCard(m, state, s))),
            h('div', {class: 'caption', text: t('Audio is never saved. Esc cancels without changing your clipboard.')}),
        ];
    }

    moduleHeader(m, s, expanded) {
        const sw = MODULE_SWITCH[m.id];
        const on = !!get(s, sw.path);
        const open = h('button', {class: 'open', 'aria-expanded': String(expanded), 'aria-label': t('%@ settings', t(m.name)),
            'data-key': `module:${m.id}`, onClick: () => this.expand(m.id)},
            h('span', {class: 'tile'}, glyph(m.symbol, 16)),
            h('span', {class: 'text'}, h('span', {class: 'name', text: t(m.name)}), h('span', {class: 'summary', text: t(m.summary)})));
        // Hover opens a card, deliberately: after a beat; never while a shortcut is recorded, after
        // a key was pressed (until the next click), or from under an insertion point (`ModuleHeader`).
        const blocked = () => this.keyboardLock || !!this.recording;
        open.addEventListener('mouseenter', () => {
            clearTimeout(this.hoverTimer);
            if (expanded || this.mode !== 'settings' || blocked())
                return;
            this.hoverTimer = setTimeout(() => {
                if (!blocked() && !document.activeElement?.matches?.('textarea, input'))
                    this.expand(m.id);
            }, 160);
        });
        open.addEventListener('mouseleave', () => clearTimeout(this.hoverTimer));
        return h('div', {class: 'module-head'}, open,
            toggleSwitch(on, {label: t(m.name), onToggle: value => this.moduleSwitch(m, value), focusKey: `switch:${m.id}`}));
    }

    async moduleSwitch(m, value) {
        await this.set(MODULE_SWITCH[m.id].key, value);
        // Dictation turned on opens its card, on the card's curve, while the switch is still on its
        // spring; or its setup page, at once, while the model or the microphone is not ready (`DictationCard`).
        if (value && m.id === 'dictation') {
            const d = dictationRows(this.state, this.s);
            if (!d.modelReady || !d.microphoneAllowed) {
                this.expandedModule = 'dictation';
                this.dictationPage = 'setup';
                this.render();
            } else {
                this.expand('dictation');
            }
        }
    }

    expand(id) {
        if (this.expandedModule === id)
            return;
        this.expandedModule = id;
        this.render();
    }

    moduleCard(m, state, s) {
        const expanded = this.expandedModule === m.id;
        const on = !!get(s, MODULE_SWITCH[m.id].path);
        const card = h('div', {class: 'card', 'data-module': m.id}, this.moduleHeader(m, s, expanded));
        if (!expanded)
            return card;
        switch (m.id) {
        case 'music': card.append(...this.musicRows(state, s)); break;
        case 'teleprompter': if (on) card.append(...this.teleprompterBody(state, s)); break;
        case 'dictation': card.append(...this.dictationBody(state, s, on)); break;
        case 'shelf': card.append(...this.shelfBody(state, s, on)); break;
        default: break;
        }
        return card;
    }

    /**
     * macOS reads the track through a part Apple does not publish; the others do not, so say
     * only what is true. The Russian sentence never mentioned it, so it is the Swift's own.
     */
    musicNote() {
        return platform === 'macos' || language === 'ru' ? t(MUSIC_NOTE) : t('Open, the surface has a page for it.');
    }

    /** `MusicModule.unreadableGuidance`, said of this system. */
    musicUnreadable() {
        return t("macOS no longer lets CapaTheNotch read what's playing.");
    }

    musicRows(state, s) {
        const rows = [h('div', {class: 'note-line', text: this.musicNote()})];
        if (s.music.enabled && state.modules?.music?.unreadable)
            rows.push(h('div', {class: 'note-line destructive', style: {padding: '10px'}, text: this.musicUnreadable()}));
        return rows;
    }

    // MARK: Teleprompter

    teleprompterBody(state, s) {
        const r = teleprompterRows(state, s);
        const area = h('textarea', {class: 'script', 'aria-label': t('Script')});
        area.value = s.teleprompter.script;
        area.addEventListener('input', () => this.set('script', area.value));
        area.addEventListener('blur', () => this.schedule());
        return [
            h('div', {class: 'block'},
                h('div', {class: 'script-wrap'}, area, h('span', {class: 'script-count', text: r.length})),
                h('div', {class: 'actions'}, r.script.buttons.map(b => button(t(b.title), {disabled: b.disabled, onClick: () => this.action(b)})))),
            h('div', {class: 'divider'}),
            h('div', {class: 'row', style: {paddingLeft: '54px'}},
                h('span', {class: 'label', text: t(r.speed.title)}),
                h('span', {class: 'mono', text: `${get(s, r.speed.path).toFixed(2)}x`}),
                h('span', {class: 'stepper'},
                    h('button', {'aria-label': t('Faster'), 'data-key': 'faster', onClick: () => this.command('faster')}, glyph('chevron.up', 7)),
                    h('button', {'aria-label': t('Slower'), 'data-key': 'slower', onClick: () => this.command('slower')}, glyph('chevron.down', 7)))),
            h('div', {class: 'divider'}),
            h('div', {class: 'row', style: {paddingLeft: '54px'}}, h('span', {class: 'label', text: t(r.textSize.title)}),
                picker({label: r.textSize.options.find(o => o.id === get(s, r.textSize.path))?.title ?? '', options: r.textSize.options,
                    value: get(s, r.textSize.path), onPick: id => this.set(r.textSize.key, id), focusKey: 'picker:textSize'})),
            h('div', {class: 'divider'}),
            h('div', {class: 'block', style: {paddingTop: '10px'}}, h('span', {text: t('Shortcuts')}),
                r.shortcuts.map(sc => h('div', {class: 'shortcut-row'},
                    h('div', {class: 'who'}, h('span', {class: 'caption', text: t(sc.title)}),
                        sc.unavailable ? h('span', {class: 'error', text: t('Another app already uses this shortcut.')}) : null),
                    this.recorder(sc.target, get(s, sc.path), {label: t('%@ shortcut', t(sc.title))})))),
        ];
    }

    /**
     * While either is recorded both Modules' shortcuts are let go, so the keys reach the page
     * and press neither (`ModuleShortcutCapture`, `AppDelegate`).
     */
    suspend(on) {
        this.host.call('dictation', 'suspend_shortcut', {suspend: on}).catch(() => {});
        this.host.call('teleprompter', 'suspendShortcuts', {suspended: on}).catch(() => {});
    }

    /**
     * Records a shortcut for `target`: the next key pressed with Ctrl, Alt or the system key
     * becomes it. `draw` is called as recording starts and ends; Escape cancels — alone for
     * the Teleprompter's recorder, with whatever is held for Dictation's editor.
     */
    capture(target, draw, {escapeAlways = false} = {}) {
        const finish = () => {
            window.removeEventListener('keydown', onKey, true);
            if (this.recording === target)
                this.suspend(false);
            this.recording = null;
            this.schedule();
            draw();
        };
        const onKey = e => {
            e.preventDefault();
            e.stopPropagation();
            if (e.key === 'Escape' && (escapeAlways || (!e.ctrlKey && !e.altKey && !e.metaKey))) {
                finish();
                return;
            }
            if (['Control', 'Alt', 'Shift', 'Meta', 'AltGraph', 'Super', 'Hyper', 'OS'].includes(e.key))
                return;
            const event = {code: e.code, key: e.key, ctrl: e.ctrlKey, alt: e.altKey, shift: e.shiftKey, meta: e.metaKey};
            if (!(e.ctrlKey || e.altKey || e.metaKey))
                return;
            this.host.call('settings', 'setShortcut', {target, event}).catch(() => {}).finally(finish);
        };
        return () => {
            if (this.recording === target) {
                finish();
                return;
            }
            clearTimeout(this.hoverTimer);
            this.recording = target;
            this.suspend(true);
            draw();
            window.addEventListener('keydown', onKey, true);
        };
    }

    /**
     * The Teleprompter's recorder (`ShortcutRecorder`): its keycaps, the key's own the wide one, and a
     * click to record. Read as its title and then the shortcut, or "None" (`.accessibilityValue`).
     */
    recorder(target, shortcut, {label = null} = {}) {
        const holder = h('button', {class: 'keycaps recorder', 'aria-label': `${label ?? t('%@ shortcut', target)}, ${shortcut?.display ?? t('None')}`,
            'data-key': `recorder:${target}`});
        const draw = () => {
            holder.replaceChildren(...(this.recording === target
                ? [h('span', {class: 'keycap wide', text: t('Type a shortcut')})]
                : (shortcut?.caps ?? ['—']).map((cap, i, all) => h('span', {class: `keycap${i === all.length - 1 ? ' wide' : ''}`, text: cap}))));
        };
        draw();
        const toggle = this.capture(target, draw);
        holder.addEventListener('click', e => {
            e.stopPropagation();
            toggle();
        });
        return holder;
    }

    /** Dictation's shortcut (`DictationShortcutEditor`): its keycaps, all alike, and Edit — "Press keys…" while recording. */
    dictationEditor(s) {
        const caps = s.dictation.shortcut?.caps ?? ['—'];
        const edit = button(t('Edit'), {focusKey: 'recorder:dictation'});
        const draw = () => { edit.textContent = this.recording === 'dictation' ? t('Press keys…') : t('Edit'); };
        draw();
        const toggle = this.capture('dictation', draw, {escapeAlways: true});
        edit.addEventListener('click', () => toggle());
        return h('span', {class: 'shortcut-editor'}, keycaps(caps), edit);
    }

    // MARK: Shelf

    shelfBody(state, s, on) {
        const out = [h('div', {class: 'note-line', text: t(SHELF_NOTE)})];
        if (!on)
            return out;
        const switchRow = spec => [
            h('div', {class: 'divider'}),
            h('div', {class: 'row', style: {minHeight: '56px', paddingLeft: '54px'}},
                h('div', {class: 'stack2'}, h('span', {text: t(spec.title)}), h('span', {class: 'caption', text: t(spec.note)})),
                toggleSwitch(!!get(s, spec.path), {label: t(spec.title), onToggle: v => this.set(spec.key, v), focusKey: `switch:${spec.key}`})),
        ];
        out.push(...switchRow(SHELF_IMAGES), ...switchRow(SHELF_TEXT));
        if (s.shelf.keepsText)
            out.push(...this.clippingRows(s));
        return out;
    }

    clippingRows(s) {
        const limit = s.shelf.clippingLimit;
        const rows = [
            h('div', {class: 'row hovers', style: {paddingLeft: '54px'}}, h('span', {class: 'label', text: t('Keep')}),
                picker({label: String(limit), options: clippingLimitOptions(s), value: limit, onPick: id => this.set('clippingLimit', id), focusKey: 'picker:clippingLimit'})),
            this.toggleRow({title: 'Forget each after 24 hours', key: 'clippingsExpire', path: 'shelf.clippingsExpire', indent: 44}, s),
            h('div', {class: 'row', style: {minHeight: '48px', paddingLeft: '54px'}},
                h('div', {class: 'stack2'}, h('span', {text: t('Never from these applications')}),
                    h('span', {class: 'caption', text: t('Passwords and Keychain Access are always left alone.')})),
                button(t('Add Application…'), {onClick: async () => {
                    const chosen = await this.host.pickApplications?.() ?? [];
                    const all = [...s.shelf.excludedApplications, ...chosen.filter(c => !s.shelf.excludedApplications.includes(c))];
                    await this.set('clipboardExcludedApplications', all);
                }, focusKey: 'addApplication'})),
        ];
        this.nameApplications(s.shelf.excludedApplications);
        for (const id of s.shelf.excludedApplications) {
            // The application's own name, or its identifier if it is gone.
            const name = this.appNames[id] || id;
            rows.push(h('div', {class: 'row hovers', style: {paddingLeft: '54px'}}, h('span', {class: 'label', text: name}),
                h('button', {class: 'plain-glyph', 'aria-label': t('Remove %@', name), 'data-key': `remove:${id}`,
                    onClick: () => this.set('clipboardExcludedApplications', s.shelf.excludedApplications.filter(x => x !== id))},
                glyph('minus.circle', 13))));
        }
        return rows;
    }

    /** Asks the window's program once for the names of applications not yet named, and draws them when they come. */
    nameApplications(ids) {
        const unknown = ids.filter(id => !(id in this.appNames));
        if (unknown.length === 0 || !this.host.applicationNames)
            return;
        unknown.forEach(id => { this.appNames[id] = ''; });
        this.host.applicationNames(unknown).then(names => {
            Object.assign(this.appNames, names ?? {});
            this.schedule();
        }).catch(() => {});
    }

    // MARK: Dictation

    dictationBody(state, s, on) {
        const d = dictationRows(state, s);
        if (!on)
            return [h('div', {class: 'note-line', text: t('Hold a shortcut to turn speech into text, entirely on this Mac.')})];
        const line = (...kids) => h('div', {class: 'row hovers', style: {paddingLeft: '54px'}}, ...kids);
        const out = [
            h('div', {class: 'divider'}),
            h('div', {class: 'row', style: {paddingLeft: '54px'}}, h('span', {class: 'label', text: t('Hold to dictate')}),
                this.dictationEditor(s)),
        ];
        if (d.shortcutUnavailable)
            out.push(h('div', {class: 'note-line destructive', style: {padding: '0 0 8px 54px'}, text: t('This shortcut is in use. Choose another.')}));
        out.push(
            h('div', {class: 'divider'}),
            line(h('span', {class: 'label', text: d.modelReady ? t('Model ready') : t('Speech model')}),
                d.modelReady
                    ? h('button', {class: 'positive', text: t('Downloaded'), onClick: () => this.openDictation('setup'), title: t('Manage speech model')})
                    : button(t('Set up'), {onClick: () => this.openDictation('setup')})),
            h('div', {class: 'divider'}),
            line(h('span', {class: 'label', text: t('Automatic insertion')}),
                d.insertionAllowed ? h('span', {class: 'positive', text: t('Allowed')})
                    // No host that can paste: there is nothing Enable could do (`.unavailable`).
                    : d.insertionUnavailable ? h('span', {class: 'caption', text: t('Unavailable')})
                        : button(t('Enable'), {onClick: () => this.openDictation('setup')})),
            h('div', {class: 'divider'}),
            line(h('span', {class: 'label', text: t('Word replacements')}), button(t('Edit'), {onClick: () => this.openDictation('replacements')})),
            h('div', {class: 'divider'}),
            this.toggleRow({title: 'Keep history', key: 'dictationKeepsHistory', path: 'dictation.keepsHistory', indent: 44}, s),
            h('div', {class: 'divider'}),
            line(h('span', {class: 'caption', style: {flex: 1}, text: d.savedResults === 0 ? t('No saved results') : t('%d saved results', d.savedResults)}),
                button(t('View history'), {onClick: () => this.openDictation('history')})));
        if (!d.microphoneAllowed)
            out.push(line(button(t('Allow microphone access'), {onClick: () => this.openDictation('setup')}), h('span', {class: 'grow'})));
        return out;
    }

    openDictation(page) {
        this.dictationPage = page;
        this.section = 'modules';
        this.render();
    }

    dictationSubpage(state, s) {
        const def = DICTATION_PAGES[this.dictationPage];
        const out = [
            h('div', {class: 'breadcrumb'},
                h('button', {class: 'back', text: t('‹ Modules / Dictation'), onClick: () => {
                    this.dictationPage = 'overview';
                    this.expandedModule = 'dictation';
                    this.render();
                }}),
                h('div', {class: 'heading'}, h('h1', {text: t(def.title)}), h('p', {text: t(def.subtitle)}))),
        ];
        if (this.dictationPage === 'setup')
            out.push(...this.dictationSetup(state, s));
        else if (this.dictationPage === 'history')
            out.push(...this.dictationHistory(s));
        else
            out.push(...this.dictationReplacements(s));
        return out;
    }

    dictationSetup(state, s) {
        const d = state?.modules?.dictation ?? {};
        const ready = !!d.modelReady, mic = d.microphoneAllowed !== false, insertion = !!d.insertionAllowed;
        const insertable = d.insertionAllowed !== false;
        const on = s.dictation.enabled;
        const call = method => this.host.call('dictation', method, null).catch(() => {});
        const step = (n, text, done) => h('div', {class: 'step'},
            h('span', {class: `badge${done ? ' done' : ''}`, text: done ? '✓' : String(n)}), h('span', {class: 'what', text}));
        const out = [];
        if (!on)
            out.push(button(t('Turn on Dictation'), {onClick: () => this.set('dictationEnabled', true)}));

        const progress = d.download ? d.download.fraction : null;
        const download = [step(1, t('Download the speech model'), ready),
            h('p', {class: 'setup-text', text: t('One download, then recognition works offline.\nGigaAM v3 · 170 MB download · 232 MB on disk')})];
        if (progress != null) {
            download.push(h('div', {class: 'progress'}, h('i', {style: {width: `${Math.round(progress * 100)}%`}})),
                h('div', {class: 'actions'}, h('span', {class: 'caption', style: {flex: 1, color: 'var(--text)'},
                    text: d.download?.label?.kind === 'checking' || progress >= 1 ? t('Checking the model…') : t('Downloading · %d%%', d.download?.label?.percent ?? Math.round(progress * 100))}),
                button(t('Cancel'), {onClick: () => call('cancel_download')})));
        } else {
            download.push(h('div', {class: 'actions'},
                h('button', {class: 'link plain', text: t('Source & licences ↗'), onClick: () => this.openLicences()}),
                h('span', {style: {flex: 1}}),
                button(t('Show in Finder'), {disabled: !ready, onClick: () => call('reveal_model')}),
                button(ready ? t('Download again') : t('Download • 170 MB'), {disabled: !on, onClick: () => call('start_download')})));
        }
        if (d.error)
            download.push(h('div', {class: 'destructive', text: t(d.error)}));
        out.push(h('div', {class: 'panel'}, download));

        out.push(h('div', {class: 'stack', style: {padding: '0 14px', gap: '10px'}},
            step(2, t('Allow microphone access'), mic),
            mic ? h('span', {class: 'caption', text: t('Granted')})
                : ready ? [h('span', {class: 'caption', text: t('Microphone access is needed only while recording.')}),
                    button(t('Allow microphone access'), {disabled: !on, onClick: () => call('request_microphone')})]
                    : h('span', {class: 'caption', text: t('Requested after the model is ready.')})));
        out.push(h('div', {class: 'stack', style: {padding: '0 14px', gap: '10px'}},
            step(3, t('Enable automatic insertion'), insertion),
            h('span', {class: 'caption', text: insertion ? t('Granted') : t('Optional. You can always paste from the clipboard.')}),
            ready && mic && !insertion && insertable ? button(t('Enable automatic insertion'), {disabled: !on, onClick: () => call('request_insertion')}) : null));
        out.push(h('div', {class: 'caption', style: {whiteSpace: 'pre-line'}, text: t('Your audio stays on this Mac and is never saved.\nText history is off unless you choose to enable it.')}));
        return out;
    }

    /**
     * The licences the speech model comes with, as shipped beside the extension (the Swift opens
     * its bundled `DictationLicenses.txt`); the repository's copy, should this install lack it.
     */
    openLicences() {
        const online = 'https://github.com/maximfakel/capa-the-notch/blob/main/Sources/CapacityNotch/Resources/DictationLicenses.txt';
        const local = this.host.extensionFile?.('DictationLicenses.txt');
        if (!local) {
            this.host.openUrl(online);
            return;
        }
        // A `file://` page reads its neighbours (the window allows it): a missing file reads empty, or fails.
        const request = new XMLHttpRequest();
        request.open('GET', local);
        request.onload = () => this.host.openUrl([0, 200].includes(request.status) && request.responseText ? local : online);
        request.onerror = () => this.host.openUrl(online);
        request.send();
    }

    dictationHistory(s) {
        const entries = s.dictation.history;
        // `.abbreviated` date and `.shortened` time, the date left out today: "Oct 5, 2026 at 3:04 PM",
        // "5 окт. 2026 г., 15:04" — Foundation joins them with "at" in English, a comma in Russian.
        const clock = at => {
            const date = new Date(at * 1000), locale = language === 'ru' ? 'ru-RU' : 'en-US';
            const time = date.toLocaleTimeString(locale, {hour: 'numeric', minute: '2-digit'});
            if (date.toDateString() === new Date().toDateString())
                return time;
            const day = date.toLocaleDateString(locale, {year: 'numeric', month: 'short', day: 'numeric'});
            return language === 'ru' ? `${day}, ${time}` : `${day} at ${time}`;
        };
        const out = [
            h('div', {class: 'card'}, h('div', {class: 'row', style: {minHeight: '56px'}},
                h('div', {class: 'stack2', style: {gap: '4px'}}, h('span', {text: t('Keep history')}),
                    h('span', {class: 'caption', text: t('Turning this off keeps your saved results.')})),
                toggleSwitch(s.dictation.keepsHistory, {label: t('Keep history'), onToggle: v => this.set('dictationKeepsHistory', v), focusKey: 'switch:keepsHistory'}))),
            h('div', {class: 'actions'}, h('span', {class: 'caption', style: {flex: 1}, text: t('%d results', entries.length)}),
                h('button', {class: 'link destructive', text: t('Clear History'), disabled: entries.length === 0,
                    onClick: () => this.command('clearHistory')})),
        ];
        if (entries.length === 0)
            out.push(h('div', {style: {color: 'var(--muted)', padding: '20px 0'},
                text: s.dictation.keepsHistory ? t('Your next dictation will appear here.') : t('No saved results. Turn on Keep history to save future dictations.')}));
        // In the history's own order, newest first, as `DictationHistory` keeps it.
        out.push(h('div', {class: 'stack', style: {gap: '8px'}}, entries.map(e =>
            h('div', {class: 'entry'},
                h('div', {class: 'when'}, h('span', {text: clock(e.date)}),
                    iconButton('copy', t('Copy'), () => this.host.copyText(e.text), {bordered: true, scale: 14 / 16, focusKey: `copy:${e.id}`}),
                    iconButton('trash', t('Delete'), () => this.command('deleteHistoryEntry', {id: e.id}), {bordered: true, scale: 14 / 16, focusKey: `delete:${e.id}`})),
                h('p', {text: e.text})))));
        return out;
    }

    dictationReplacements(s) {
        const rules = s.dictation.replacements.map(r => ({...r}));
        const save = () => this.set('dictationReplacements', rules);
        const line = (rule, i) => {
            const field = (label, key) => {
                const input = h('input', {type: 'text', 'aria-label': label, placeholder: label});
                input.value = rule[key];
                input.addEventListener('input', () => { rule[key] = input.value; save(); });
                return input;
            };
            const box = h('input', {type: 'checkbox', 'aria-label': t('Enable %@', rule.heard)});
            box.checked = rule.enabled;
            box.addEventListener('change', () => { rule.enabled = box.checked; save(); });
            return h('div', {class: 'line'}, box, field(t('Recognised phrase'), 'heard'), field(t('Replacement'), 'replacement'),
                h('button', {class: 'plain-glyph replacement-delete', 'aria-label': t('Delete %@ replacement', rule.heard), title: t('Delete replacement'),
                    onClick: () => { rules.splice(i, 1); save(); }}, glyph('minus', 13)));
        };
        return [
            h('div', {class: 'actions'}, h('span', {class: 'caption', style: {flex: 1}, text: t('%d active rules', rules.filter(r => r.enabled).length)}),
                button(t('+ Add replacement'), {onClick: () => {
                    const id = rules.reduce((m, r) => Math.max(m, r.id), 0) + 1;
                    rules.unshift({id, heard: '', replacement: '', enabled: true});
                    this.set('dictationReplacements', rules);
                }})),
            h('div', {class: 'table'},
                h('div', {class: 'head'}, h('i'), h('span', {text: t('Recognised')}), h('span', {text: t('Replace with')}), h('i')),
                rules.map(line)),
            h('div', {class: 'caption', style: {whiteSpace: 'pre-line'}, text: t('Matches whole words and phrases, ignoring letter case.\nChanges apply to your next dictation.')}),
        ];
    }

    // MARK: - Onboarding

    onboardingSidebar(s) {
        const providerAnswered = this.providerAnswered(s);
        const skipped = this.reached > 2 && !providerAnswered;
        return h('div', {class: 'sidebar', role: 'navigation', 'aria-label': t('Onboarding steps')},
            h('div', {class: 'highlight', 'aria-hidden': 'true'}),
            ONBOARDING_STEPS.map((step, i) => {
                const reachable = i <= this.reached;
                const passed = i < this.reached && !(i === 2 && skipped);
                const marker = passed ? '✓' : i === 2 && skipped ? '–' : String(i + 1);
                const said = passed ? t('Done') : i === 2 && skipped ? t('Skipped') : t('Step %d', i + 1);
                return h('button', {class: `side-item${i === this.step ? ' selected' : ''}`, disabled: !reachable, 'data-key': `step:${step.id}`,
                    onClick: () => { this.step = i; this.render(); }},
                    icon(step.icon, 1), h('span', {class: 'title', text: t(step.name)}),
                    keycaps([marker], {positive: passed, label: said}));
            }),
            h('div', {class: 'grow'}),
            h('div', {class: 'note', text: t('Everything chosen here can be changed later in Settings.')}));
    }

    providerAnswered(s) {
        const views = new Map((this.state?.providers ?? []).map(p => [p.provider, p]));
        return s.providers.some(p => p.on && ['fresh', 'stale'].includes(views.get(p.provider)?.state));
    }

    onboardingPage(state, s) {
        const step = ONBOARDING_STEPS[this.step];
        const page = h('div', {class: 'page onboarding'}, this.heading(step.title, step.subtitle));
        const content = this[`step_${step.id}`](state, s);
        page.append(...[].concat(content));
        return page;
    }

    footer(s) {
        const last = this.step === ONBOARDING_STEPS.length - 1;
        const canGoOn = this.step !== 2 || this.providerAnswered(s);
        return h('div', {class: 'footer'},
            this.step !== 0 ? button(t('Back'), {onClick: () => { this.step -= 1; this.render(); }, focusKey: 'back'}) : null,
            h('span', {class: 'grow'}),
            !canGoOn ? button(t('Skip'), {onClick: () => this.advance(last), focusKey: 'skip'}) : null,
            button(last ? t('Finish') : t('Continue'), {prominent: true, disabled: !canGoOn, onClick: () => this.advance(last), focusKey: 'goOn'}));
    }

    async advance(last) {
        if (last) {
            // The Module remembers it, plays the sound and says `onboardingFinished`; the surface opens on that.
            await this.command('finishOnboarding');
            this.host.close();
            return;
        }
        this.step += 1;
        this.reached = Math.max(this.reached, this.step);
        this.render();
    }

    step_welcome(state, s) {
        const feature = (iconName, name, summary) => h('div', {class: 'row feature'}, icon(iconName, 1),
            h('div', {class: 'stack2'}, h('span', {class: 'name', text: name}), h('span', {class: 'caption', text: summary})));
        return [
            h('div', {class: 'card'},
                feature('providers', t('Capacity'), t('What is left of each window, and whether it will last.')),
                ...['music', 'teleprompter', 'dictation'].flatMap(id => {
                    const m = MODULES.find(x => x.id === id);
                    return [h('div', {class: 'divider'}), feature(m.icon, t(m.name), t(m.summary))];
                })),
            h('div', {class: 'group'},
                h('div', {class: 'card'}, this.pickerRow({title: 'Language', key: 'language', path: 'language',
                    options: blocksFor('general', state, s)[0].rows[0].options}, s)),
                h('div', {class: 'footnote', text: t('Settings and the notch speak it; you can change it at any time.')})),
        ];
    }

    step_permissions(state, s) {
        const rows = accessRows(state, s.platform);
        return [
            h('div', {class: 'group'},
                h('div', {class: 'card'}, rows.flatMap((r, i) => [i > 0 ? h('div', {class: 'divider'}) : null,
                    h('div', {class: 'row access'}, icon(r.icon, 1),
                        h('div', {class: 'stack2', style: {padding: 0}}, h('span', {style: {fontWeight: 500}, text: t(r.name)}), h('span', {class: 'caption', text: t(r.reason)})),
                        r.state === 'granted' ? h('span', {class: 'positive', text: t('Granted')})
                            : r.state === 'unavailable' ? h('span', {class: 'caption', text: t('Unavailable')})
                                : button(t('Allow'), {onClick: () => this.host.call(r.ask.module, r.ask.method, null).catch(() => {})}))])),
                h('div', {class: 'footnote', text: t('macOS asks about each one in turn. Accessibility is switched on in System Settings; its state here follows when you come back.')})),

            // Only what has not been asked yet (`SystemAccess.anyToAsk`).
            h('div', {class: 'actions'}, button(t('Allow All'), {prominent: true,
                disabled: !rows.some(r => r.state === 'notAsked'),
                onClick: () => rows.filter(r => r.state === 'notAsked').forEach(r => this.host.call(r.ask.module, r.ask.method, null).catch(() => {}))})),
        ];
    }

    step_providers(state, s) {
        const out = [h('div', {class: 'group'}, this.providerCards(state, s),
            h('div', {class: 'footnote', text: t('Claude Code and OpenCode are experimental. CapaTheNotch says what it reads before reading anything.')}))];
        // Asked only once a Provider has answered, and neither is set for anyone.
        if (this.providerAnswered(s)) {
            out.push(h('div', {class: 'group', 'data-appear': 'alerts'}, h('div', {class: 'card'},
                this.toggleRow({title: 'Warn me when a window is about to run out', key: 'alertsEnabled', path: 'alertsEnabled'}, s),
                h('div', {class: 'divider'}),
                this.toggleRow({title: 'Launch at login', key: 'launchAtLogin', path: 'launchAtLogin'}, s)),
            h('div', {class: 'footnote', text: t('One warning per window, when it first drops below a tenth left, and nothing more until it recovers or resets.')})));
        }
        return out;
    }

    moduleCardOnboarding(id, s, {note = null, warning = null} = {}) {
        const m = MODULES.find(x => x.id === id);
        const sw = MODULE_SWITCH[id];
        // `ModuleCard`: a `SettingsRow` (56 high, 12 apart) that lights up under the pointer.
        const card = h('div', {class: 'card'},
            h('div', {class: 'module-head hovers'},
                h('span', {class: 'open', style: {cursor: 'default'}}, h('span', {class: 'tile'}, icon(m.icon, 1)),
                    h('span', {class: 'text'}, h('span', {class: 'name', text: t(m.name)}), h('span', {class: 'summary', text: t(m.summary)}))),
                toggleSwitch(!!get(s, sw.path), {label: t(m.name), onToggle: v => this.set(sw.key, v), focusKey: `switch:${id}`})));
        for (const line of [note, warning].filter(Boolean))
            card.append(h('div', {class: `note-line${line === warning ? ' warning' : ''}`, text: line}));
        return card;
    }

    step_music(state, s) {
        const warning = s.music.enabled && state.modules?.music?.unreadable ? this.musicUnreadable() : null;
        return this.moduleCardOnboarding('music', s, {note: this.musicNote(), warning});
    }

    step_teleprompter(state, s) {
        const out = [this.moduleCardOnboarding('teleprompter', s)];
        if (s.teleprompter.enabled) {
            // Shown at once: the switch's spring is the switch's own (`OnboardingTeleprompter`).
            out.push(h('div', {class: 'group'}, h('div', {class: 'card'},
                s.choices.teleprompterActions.map(a => {
                    const shortcut = s.teleprompter.shortcuts[a.id];
                    return h('div', {class: 'row'}, h('span', {class: 'label', text: t(a.title)}),
                        keycaps(shortcut?.caps ?? ['—'], {label: `${t('%@ shortcut', t(a.title))}, ${shortcut?.display ?? t('None')}`}));
                })),
            h('div', {class: 'footnote', text: t('Write or paste the Script in Settings, under Modules. The shortcuts can be changed there too.')})));
        }
        return out;
    }

    step_dictation(state, s) {
        const out = [this.moduleCardOnboarding('dictation', s,
            {note: s.dictation.enabled ? null : t('Hold a shortcut to turn speech into text, entirely on this Mac.')})];
        if (s.dictation.enabled) {
            const d = dictationRows(state, s);
            const card = h('div', {class: 'card'}, h('div', {class: 'row', style: {gap: '12px'}}, h('span', {class: 'label', text: t('Hold to dictate')}),
                this.dictationEditor(s)));
            if (d.shortcutUnavailable)
                card.append(h('div', {class: 'note-line destructive', style: {padding: '0 10px 8px 10px'}, text: t('This shortcut is in use. Choose another.')}));
            out.push(card, ...this.dictationSetup(state, s));
        }
        return out;
    }
}
