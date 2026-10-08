// The small pieces both windows are built from: elements, the switch, the
// picker with its menu, buttons, keycaps, the consent dialog, and the icons
// (drawn with the same code the surface draws them with).

import {CairoCanvas} from '../cairo-canvas.js';
import {drawIcon, iconGrid} from '../ui/icons.js';
import {drawMark} from '../marks.js';
import {REDUCED, SPRING} from './motion.js';

export function h(tag, props = {}, ...children) {
    const el = document.createElement(tag);
    for (const [k, v] of Object.entries(props ?? {})) {
        if (v === undefined || v === null || v === false)
            continue;
        if (k === 'class')
            el.className = v;
        else if (k === 'style' && typeof v === 'object')
            Object.assign(el.style, v);
        else if (k.startsWith('on'))
            el.addEventListener(k.slice(2).toLowerCase(), v);
        else if (k === 'text')
            el.textContent = v;
        else if (v === true)
            el.setAttribute(k, '');
        else
            el.setAttribute(k, v);
    }
    for (const child of children.flat(Infinity)) {
        if (child === undefined || child === null || child === false)
            continue;
        el.append(child.nodeType ? child : document.createTextNode(String(child)));
    }
    return el;
}

const RATIO = () => Math.max(window.devicePixelRatio || 1, 2);

/** An icon in the colour of the text around it: drawn in black and used as a mask. */
export function icon(name, scale = 1, {className = 'icon'} = {}) {
    const [gw, gh] = iconGrid(name);
    const w = gw * scale, h_ = gh * scale, ratio = RATIO();
    const canvas = document.createElement('canvas');
    canvas.width = Math.ceil(w * ratio);
    canvas.height = Math.ceil(h_ * ratio);
    const ctx = canvas.getContext('2d');
    ctx.scale(ratio, ratio);
    const cr = new CairoCanvas(ctx);
    const g = {cr, color: c => cr.setSourceRGBA(c[0], c[1], c[2], c[3] ?? 1)};
    drawIcon(g, name, w / 2, h_ / 2, scale, [0, 0, 0, 1]);
    const url = `url(${canvas.toDataURL()})`;
    const span = document.createElement('span');
    span.className = className;
    Object.assign(span.style, {
        display: 'inline-block', width: `${w}px`, height: `${h_}px`, flex: 'none',
        backgroundColor: 'currentColor', webkitMaskImage: url, maskImage: url,
        webkitMaskSize: '100% 100%', maskSize: '100% 100%',
    });
    return span;
}

/** A Provider's mark: Claude in its orange, the others in the text colour. */
export function mark(provider, size) {
    const ratio = RATIO();
    const canvas = document.createElement('canvas');
    canvas.width = Math.ceil(size * ratio);
    canvas.height = Math.ceil(size * ratio);
    const ctx = canvas.getContext('2d');
    ctx.scale(ratio, ratio);
    drawMark(new CairoCanvas(ctx), provider, size, 1);
    if (provider === 'claudeCode') {
        canvas.style.width = `${size}px`;
        canvas.style.height = `${size}px`;
        canvas.style.flex = 'none';
        return canvas;
    }
    const url = `url(${canvas.toDataURL()})`;
    const span = document.createElement('span');
    Object.assign(span.style, {
        display: 'inline-block', width: `${size}px`, height: `${size}px`, flex: 'none', backgroundColor: 'currentColor',
        webkitMaskImage: url, maskImage: url, webkitMaskSize: '100% 100%', maskSize: '100% 100%',
    });
    return span;
}

const SVG = 'http://www.w3.org/2000/svg';

/**
 * The few SF Symbols the Swift draws in place of `SettingsIcon`s, at their
 * point size and in the colour of the text around them: `chevron.up` and
 * `chevron.down` (bold), `minus`, `minus.circle`; and the Modules' own, which
 * `ModuleHeader` draws at 16 points in its tile (`BuiltInModule.symbol`):
 * `music.note`, `text.alignleft`, `mic`, `tray`. Those are drawn on a grid of
 * points at that size (`pt`), so each keeps the symbol's own proportions.
 */
export function glyph(name, size) {
    const shapes = {
        'chevron.up': {box: [10, 6], weight: 1.9, draw: [['polyline', {points: '1.2,5 5,1.2 8.8,5'}]]},
        'chevron.down': {box: [10, 6], weight: 1.9, draw: [['polyline', {points: '1.2,1 5,4.8 8.8,1'}]]},
        'minus': {box: [12, 12], weight: 1.3, draw: [['line', {x1: 2, y1: 6, x2: 10, y2: 6}]]},
        'minus.circle': {box: [12, 12], weight: 1.1,
            draw: [['circle', {cx: 6, cy: 6, r: 5.2}], ['line', {x1: 3.6, y1: 6, x2: 8.4, y2: 6}]]},
        'music.note': {box: [11, 16], pt: 16, weight: 1.4, draw: [
            ['ellipse', {cx: 3.7, cy: 12.7, rx: 3, ry: 2.3, transform: 'rotate(-18 3.7 12.7)', fill: 'currentColor', stroke: 'none'}],
            ['line', {x1: 6.2, y1: 12.4, x2: 6.2, y2: 1.6}],
            ['path', {d: 'M5.5 0.9 L10.3 0.2 V3.4 L5.5 4.1 Z', fill: 'currentColor', stroke: 'none'}]]},
        'text.alignleft': {box: [16, 13], pt: 16, weight: 1.4, draw: [
            ['line', {x1: 0.9, y1: 1.2, x2: 15.1, y2: 1.2}], ['line', {x1: 0.9, y1: 4.7, x2: 10.2, y2: 4.7}],
            ['line', {x1: 0.9, y1: 8.2, x2: 15.1, y2: 8.2}], ['line', {x1: 0.9, y1: 11.7, x2: 8, y2: 11.7}]]},
        'mic': {box: [12, 17], pt: 16, weight: 1.4, draw: [
            ['rect', {x: 3.3, y: 0.8, width: 5.4, height: 10, rx: 2.7}],
            ['path', {d: 'M0.9 7.6 A5.1 5.1 0 0 0 11.1 7.6'}],
            ['line', {x1: 6, y1: 12.7, x2: 6, y2: 15.6}], ['line', {x1: 3.4, y1: 15.9, x2: 8.6, y2: 15.9}]]},
        'tray': {box: [18, 13], pt: 16, weight: 1.4, draw: [
            ['rect', {x: 0.8, y: 0.8, width: 16.4, height: 11.4, rx: 2.6}],
            ['path', {d: 'M0.8 7.1 H5.4 C5.7 8.6 7.1 9.6 9 9.6 C10.9 9.6 12.3 8.6 12.6 7.1 H17.2'}]]},
    }[name];
    const [bw, bh] = shapes.box;
    const unit = shapes.pt ? size / shapes.pt : size / Math.max(bw, bh);
    const width = bw * unit, height = bh * unit;
    const svg = document.createElementNS(SVG, 'svg');
    for (const [k, v] of Object.entries({viewBox: `0 0 ${bw} ${bh}`, width, height, fill: 'none', stroke: 'currentColor',
        'stroke-width': shapes.weight, 'stroke-linecap': 'round', 'stroke-linejoin': 'round', 'aria-hidden': 'true', class: 'glyph'}))
        svg.setAttribute(k, v);
    for (const [tag, attrs] of shapes.draw) {
        const el = document.createElementNS(SVG, tag);
        for (const [k, v] of Object.entries(attrs))
            el.setAttribute(k, v);
        svg.append(el);
    }
    return svg;
}

/** Keycaps; with a `label`, read as that one thing rather than cap by cap (`.accessibilityLabel`). */
export function keycaps(caps, {wideLast = false, positive = false, label = null} = {}) {
    return h('span', {class: 'keycaps', role: label ? 'img' : null, 'aria-label': label}, caps.map((cap, i) =>
        h('span', {class: `keycap${wideLast && i === caps.length - 1 ? ' wide' : ''}${positive ? ' positive' : ''}`, text: cap})));
}

/** Reduce Motion, as the system has it. */
export const reduced = () => !!window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;

/** `SettingsMotion.spring`: switches and the sidebar's highlight; `.easeInOut(duration: 0.15)` under Reduce Motion. */
export const springMotion = () => (reduced() ? REDUCED : SPRING);

/**
 * What each switch showed when the page was last drawn, by key: whether it was
 * on, where its thumb and colour stood, and the springs it was on. A switch
 * drawn again carries on with its spring rather than starting at rest; one
 * whose value changed under it (the hub kept another, or something else set
 * it) springs there from where it stood, as `.animation(_:value:)` does
 * whatever changed the value.
 */
let drawn = new Map();

const knobAt = el => {
    const transform = getComputedStyle(el.firstElementChild).transform;
    return !transform || transform === 'none' ? 0 : new DOMMatrixReadOnly(transform).m41;
};

/** Before the page is drawn again: notes every switch in `root`; `keep` false forgets them (a new section or step). */
export function noteSwitches(root, keep) {
    drawn = new Map();
    if (!keep)
        return;
    for (const el of root.querySelectorAll('.switch[data-key]')) {
        // Not one in a page that is fading away.
        if (el.closest('[inert]'))
            continue;
        drawn.set(el.dataset.key, {
            on: el.classList.contains('on'), x: knobAt(el), color: getComputedStyle(el).backgroundColor,
            springs: el.getAnimations({subtree: true}).filter(a => a.playState === 'running')
                .map(a => ({knob: a.effect.target !== el, keyframes: a.effect.getKeyframes(), timing: a.effect.getTiming(),
                    start: a.startTime, time: a.currentTime})),
        });
    }
}

/**
 * Switches flipped whose write has not come back, by key: drawn as flipped
 * meanwhile, as the Swift's binding is, so a page drawn from the state before
 * the write does not spring them back and forth.
 */
const writing = new Map();

/**
 * `el.animate`, kept on the page's own thread. WebKitGTK hands an opacity or transform motion
 * to its compositor, which now and then draws the motion's first frame once more as it ends:
 * a page or the sidebar's highlight flicks back to where it came from for a frame. A custom
 * property moving along with it is one the compositor cannot run, so the page runs it all.
 */
export function animate(el, keyframes, timing) {
    return el.animate(keyframes.map((k, i) => ({...k, '--capa-motion': String(i)})), timing);
}

/**
 * A motion started again on what is drawn in its element's place, on the same clock as the one
 * it carries on: from the same start, or (one not yet started) from as far as it had gone.
 */
export function carry(motion, {start, time}) {
    if (start !== null && start !== undefined)
        motion.startTime = start;
    else
        motion.currentTime = time;
    return motion;
}

const switchColor = on => getComputedStyle(document.documentElement).getPropertyValue(on ? '--accent' : '--switch-off').trim();

/** The thumb and the colour, on the spring, from where they stood to where `on` puts them. */
function spring(el, on, from) {
    const timing = springMotion();
    animate(el.firstElementChild, [{transform: `translateX(${from.x}px)`}, {transform: `translateX(${on ? 14 : 0}px)`}], timing);
    animate(el, [{backgroundColor: from.color}, {backgroundColor: switchColor(on)}], timing);
}

export function toggleSwitch(value, {disabled = false, label = '', onToggle, focusKey}) {
    const key = focusKey ?? (label ? `switch:${label}` : undefined);
    const on = key && writing.has(key) ? writing.get(key) : value;
    const el = h('span', {
        class: `switch${on ? ' on' : ''}${disabled ? ' off-limits' : ''}`, role: 'switch', tabindex: disabled ? '-1' : '0',
        'aria-checked': String(on), 'aria-label': label, 'data-key': key,
    }, h('span', {class: 'knob'}));
    const before = key ? drawn.get(key) : null;
    if (before && before.on !== on) {
        spring(el, on, before);
    } else if (before) {
        for (const s of before.springs)
            carry(animate(s.knob ? el.firstElementChild : el, s.keyframes, s.timing), s);
    }
    const flip = () => {
        if (disabled)
            return;
        // From wherever it is, when flipped back mid-way.
        const from = {x: knobAt(el), color: getComputedStyle(el).backgroundColor};
        el.getAnimations({subtree: true}).forEach(a => a.cancel());
        el.classList.toggle('on');
        const now = el.classList.contains('on');
        el.setAttribute('aria-checked', String(now));
        spring(el, now, from);
        if (key)
            writing.set(key, now);
        Promise.resolve(onToggle(now)).finally(() => {
            if (writing.get(key) === now)
                writing.delete(key);
        });
    };
    el.addEventListener('click', e => { e.stopPropagation(); flip(); });
    el.addEventListener('keydown', e => { if (e.key === ' ' || e.key === 'Enter') { e.preventDefault(); flip(); } });
    return el;
}

export function button(title, {onClick, prominent = false, disabled = false, className = '', focusKey} = {}) {
    const b = h('button', {class: `btn${prominent ? ' prominent' : ''} ${className}`, text: title, disabled, 'data-key': focusKey ?? `button:${title}`});
    b.addEventListener('click', e => { e.stopPropagation(); onClick?.(e); });
    return b;
}

export function iconButton(name, label, onClick, {disabled = false, bordered = false, scale = 1, focusKey} = {}) {
    const b = h('button', {class: `icon-btn${bordered ? ' bordered' : ''}`, 'aria-label': label, title: label, disabled,
        'data-key': focusKey ?? `icon:${label}`}, icon(name, scale));
    b.addEventListener('click', e => { e.stopPropagation(); onClick(e); });
    return b;
}

let openMenu = null;
const menuClosed = new Set();

/** Whether a pop-up menu is open: the page is not redrawn under it. */
export const isMenuOpen = () => !!openMenu;

/** Called each time a menu closes, so what waited for it can be drawn. */
export const onMenuClose = fn => menuClosed.add(fn);

export function closeMenu() {
    if (!openMenu)
        return;
    const {menu, control} = openMenu;
    openMenu = null;
    const hadFocus = menu.contains(document.activeElement);
    menu.remove();
    if (hadFocus && control.isConnected)
        control.focus({preventScroll: true});
    menuClosed.forEach(fn => fn());
}

/**
 * A pop-up choice: the small control with its chevrons, and the menu it opens
 * (`.menuStyle(.button)`, `.menuIndicator(.hidden)`): the choices as plain
 * lines, no tick, starting under the control's left edge.
 */
export function picker({label, options, value, onPick, disabled = false, focusKey}) {
    const el = h('button', {class: 'picker', disabled, 'aria-label': label, 'aria-haspopup': 'menu', 'data-key': focusKey ?? `picker:${label}`},
        h('span', {text: label}), icon('chevrons', 1, {className: 'icon'}));
    el.addEventListener('click', e => {
        e.stopPropagation();
        if (openMenu) {
            const same = openMenu.control === el;
            closeMenu();
            if (same)
                return;
        }
        const rect = el.getBoundingClientRect();
        const items = options.map(o =>
            h('button', {role: 'menuitemradio', 'aria-checked': String(o.id === value),
                onClick: ev => { ev.stopPropagation(); closeMenu(); onPick(o.id); }}, o.title));
        const menu = h('div', {class: 'menu', role: 'menu'}, items);
        menu.addEventListener('keydown', ev => {
            const i = items.indexOf(document.activeElement);
            if (ev.key === 'ArrowDown' || ev.key === 'ArrowUp') {
                ev.preventDefault();
                items[(i + (ev.key === 'ArrowDown' ? 1 : items.length - 1)) % items.length]?.focus();
            }
        });
        document.body.append(menu);
        const width = menu.offsetWidth, height = menu.offsetHeight;
        menu.style.left = `${Math.max(8, Math.min(rect.left, window.innerWidth - width - 8))}px`;
        const below = rect.bottom + 4 + height <= window.innerHeight - 8;
        menu.style.top = `${below ? rect.bottom + 4 : Math.max(8, rect.top - 4 - height)}px`;
        openMenu = {menu, control: el};
        // Opened from the keyboard: the chosen line takes focus, so the arrows and Return work.
        if (e.detail === 0)
            (items[options.findIndex(o => o.id === value)] ?? items[0])?.focus();
    });
    return el;
}

document.addEventListener('click', () => closeMenu());
window.addEventListener('blur', () => closeMenu());
// An open menu takes Escape for itself, before anything else in the window sees it.
window.addEventListener('keydown', e => {
    if (openMenu && e.key === 'Escape') {
        e.preventDefault();
        e.stopPropagation();
        closeMenu();
    }
}, true);

/** The consent dialog and its kind: a title, a paragraph and two buttons. Resolves true for the first. */
export function dialog({title, body, ok, cancel}) {
    return new Promise(resolve => {
        const done = value => {
            window.removeEventListener('keydown', escape, true);
            scrim.remove();
            resolve(value);
        };
        // Escape is Cancel, as in the Swift's alert.
        const escape = e => {
            if (e.key === 'Escape') {
                e.preventDefault();
                e.stopPropagation();
                done(false);
            }
        };
        window.addEventListener('keydown', escape, true);
        const scrim = h('div', {class: 'scrim', onClick: e => { if (e.target === scrim) done(false); }},
            h('div', {class: 'dialog', role: 'alertdialog', 'aria-label': title},
                h('h2', {text: title}), h('p', {text: body}),
                h('div', {class: 'buttons'},
                    button(cancel, {onClick: () => done(false)}),
                    button(ok, {prominent: true, onClick: () => done(true)}))));
        document.body.append(scrim);
        scrim.querySelector('.btn.prominent').focus();
    });
}
