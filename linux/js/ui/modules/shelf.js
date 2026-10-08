// The Shelf's page: files set down on the notch, the screenshots that land
// there, and what was copied — three Shelf Tabs. `ShelfPage`, `ShelfTile`,
// `ClippingCard`, `ShelfEmptyZone` and `ShelfDropArea` in ShelfViews.swift,
// at its coordinates ("Notch — Expanded — Shelf" and "— Shelf empty").
//
// What it reads (`ctx.module`, the hub's `state.modules.shelf`): `view`
// (`ShelfView`), `thumbnails` {id: path}, `counts` {files, screenshots,
// clipboard}. What it asks (`scene.actions`): `call(module, method, args)`,
// `startFileDrag(path, item)` (a native drag of a file out), `writeClipboard(text)`.

import {Colors, Type} from '../metrics.js';
import {Spring, ease} from '../springs.js';
import {clock} from '../format.js';
import {t} from '../strings.js';
import {PRESSED_OPACITY, isPressed} from '../widgets.js';

const TILE = 76;
const CARD = {w: 148, h: 108};
const ROW_H = 108;
const GAP = 8;
const ZONE_H = 108;
const REST_SIZE = 34;
const NEAR_SIZE = 98;

const BLUE = [0x0A / 255, 0x84 / 255, 1];
const GREY = [0x8E / 255, 0x8E / 255, 0x8E / 255];
const KIND_COLOUR = {
    pdf: Colors.red, presentation: Colors.orange, document: BLUE, spreadsheet: Colors.green,
    archive: GREY, image: GREY, other: GREY,
};
const TAB_TITLE = {files: 'Files', screenshots: 'Screenshots', clipboard: 'Clipboard'};
const TABS = ['files', 'screenshots', 'clipboard'];
/** Finder moves a dragged file a moment after the drop; it is looked for again once it has. */
const AFTER_DRAG_MS = 600;
/** How far the header's left side rises while the landed Kapa stands in it (its 22 below the baseline). */
const LANDED_RISE = 1.3;

/** Wall-clock seconds: a landing is timed from when the state said so, whether or not frames were drawn. */
const wall = () => Date.now() / 1000;

/** What the page remembers between frames: each tab's scroll, what landed when, the drop area's grow. */
function ui(scene) {
    return (scene.moduleUi.shelf ??= {
        scroll: {files: 0, screenshots: 0, clipboard: 0},
        tab: null,
        kept: null,
        landedAt: -1e9,
        landedFrom: 0,
        visible: false,
        near: scene.addSpring(new Spring(0, 0.38, 0.72, {epsilon: 0.002})),
    });
}

/** Whether the page can be seen (`pageView`'s `visible`): the surface open, on it or between pages. */
function isVisible(scene, ctx) {
    return !!ctx.expanded && (ctx.selectedPage === 'shelf' || scene.travel !== 0);
}

/**
 * The landed Kapa's opacity at `at`: in on `easeOut(0.15)` from wherever it stood
 * when the last landing came, held, and out on `easeIn(0.2)` 1.8 seconds after it.
 */
function landedAlpha(u, at) {
    const age = at - u.landedAt;
    if (age < 0)
        return u.landedFrom;
    if (age < 0.15)
        return u.landedFrom + (1 - u.landedFrom) * ease.out(age / 0.15);
    if (age < 1.8)
        return 1;
    if (age < 2.0)
        return 1 - ease.in((age - 1.8) / 0.2);
    return 0;
}

function refreshAvailability(scene) {
    Promise.resolve(scene.actions.call?.('shelf', 'refreshAvailability', {})).catch(() => {});
}

/**
 * What the page notices as state arrives and as the surface is drawn, drawn or
 * not itself (Swift builds every page): something landing — whichever tab, a
 * reaction timed from then — and the page coming into view, when a file moved
 * since is looked for (`onChange(of: kept)`, `onChange(of: isVisible)`).
 */
export function observe(scene, ctx) {
    const u = ui(scene);
    const view = ctx.module?.view;
    if (view) {
        const kept = view.files.length + view.screenshots.length + view.clippings.length;
        // Twenty dropped at once land as one: one gulp, held 1.8 seconds from the last of them.
        if (u.kept != null && kept > u.kept) {
            const at = wall();
            u.landedFrom = landedAlpha(u, at);
            u.landedAt = at;
        }
        u.kept = kept;
    }
    const visible = !!view?.enabled && isVisible(scene, ctx);
    if (visible && !u.visible)
        refreshAvailability(scene);
    u.visible = visible;
}

/** The page's own text sizes. */
const F = {
    title: Type.geist(15, 600),
    count: Type.geist(12),
    clear: Type.geist(13, 500),
    tab: Type.geist(13, 500),
    name: Type.geist(11),
    badge: Type.geist(8, 700),
    moved: Type.geist(10),
    clip: Type.geist(12),
    clipTime: Type.geist(10),
    clipTimeBold: Type.geist(10, 600),
    zoneTitle: Type.geist(15, 500),
    zoneDetail: Type.geist(11),
};

const quad = (cr, x0, y0, cx, cy, x, y) =>
    cr.curveTo(x0 + (2 / 3) * (cx - x0), y0 + (2 / 3) * (cy - y0), x + (2 / 3) * (cx - x), y + (2 / 3) * (cy - y), x, y);

/** A page with its corner folded, on the drawing's 30 by 38. */
function pageGlyph(g, x, y, w, h, color) {
    const cr = g.cr, sx = w / 30, sy = h / 38;
    const X = v => x + v * sx, Y = v => y + v * sy;
    g.color(color);
    cr.newPath();
    cr.moveTo(X(4), Y(1));
    cr.lineTo(X(19), Y(1));
    cr.lineTo(X(29), Y(11));
    cr.lineTo(X(29), Y(33));
    quad(cr, X(29), Y(33), X(29), Y(37), X(25), Y(37));
    cr.lineTo(X(4), Y(37));
    quad(cr, X(4), Y(37), X(0), Y(37), X(0), Y(33));
    cr.lineTo(X(0), Y(5));
    quad(cr, X(0), Y(5), X(0), Y(1), X(4), Y(1));
    cr.closePath();
    cr.fill();
}

/** An arrow into a tray, the drawing's drop sign, on 22 by 22. */
function dropGlyph(g, x, y, color) {
    const cr = g.cr, s = 1;
    const X = v => x + v * s, Y = v => y + v * s;
    g.color(color);
    cr.setLineWidth(1.6);
    cr.setLineCap(1);
    cr.setLineJoin(1);
    cr.newPath();
    cr.moveTo(X(11), Y(3));
    cr.lineTo(X(11), Y(14));
    cr.moveTo(X(6.5), Y(9.5));
    cr.lineTo(X(11), Y(14));
    cr.lineTo(X(15.5), Y(9.5));
    cr.moveTo(X(4), Y(16));
    cr.lineTo(X(4), Y(17.5));
    quad(cr, X(4), Y(17.5), X(4), Y(19), X(5.5), Y(19));
    cr.lineTo(X(16.5), Y(19));
    quad(cr, X(16.5), Y(19), X(18), Y(19), X(18), Y(17.5));
    cr.lineTo(X(18), Y(16));
    cr.stroke();
}

/**
 * A plain button's label, dimmed while it is held down (`.buttonStyle(.plain)`):
 * as one picture, since its parts overlap.
 */
function pressable(g, scene, id, draw) {
    const group = g.group ?? g.withAlpha;
    group.call(g, isPressed(scene, id) ? PRESSED_OPACITY : 1, draw);
}

/** The ✕ that stands out of a tile's corner: 18 across, a black ring round it. */
function removeButton(g, scene, id, cx, cy, onClick, label) {
    pressable(g, scene, id, () => {
        g.fillCircle(cx, cy, 11, Colors.black);
        g.fillCircle(cx, cy, 9, [0x3A / 255, 0x3A / 255, 0x3A / 255]);
        const cr = g.cr, a = 2.7;
        g.color(Colors.white);
        cr.setLineWidth(1.5);
        cr.setLineCap(1);
        cr.newPath();
        cr.moveTo(cx - a, cy - a);
        cr.lineTo(cx + a, cy + a);
        cr.moveTo(cx + a, cy - a);
        cr.lineTo(cx - a, cy + a);
        cr.stroke();
    });
    scene.addHit({id, x: cx - 9, y: cy - 9, w: 18, h: 18, onClick, label});
}

/**
 * The pieces a line may end after, as UAX #14 has it for what the Shelf shows: a
 * word with the space after it, or a run up to a hyphen — not one before a digit,
 * so "2026-10-05" holds together.
 */
function breakable(text) {
    const pieces = [];
    let piece = '';
    for (let i = 0; i < text.length; i++) {
        const ch = text[i];
        piece += ch;
        const next = text[i + 1];
        if (ch === ' ' && next !== ' ' || ch === '-' && next !== undefined && !/[\d\s-]/.test(next) && piece.trim().length > 1) {
            pieces.push(piece);
            piece = '';
        }
    }
    if (piece)
        pieces.push(piece);
    return pieces;
}

/** Lines no wider than `width`, broken where `breakable` allows; a piece wider than that breaks where it must. */
export function wrapText(g, text, font, width) {
    const lines = [];
    let line = '';
    for (const piece of breakable(String(text))) {
        const trial = line + piece;
        if (g.measureText(trial.trimEnd(), font) <= width) {
            line = trial;
            continue;
        }
        if (line.trim())
            lines.push(line.trimEnd());
        let rest = piece;
        while (g.measureText(rest.trimEnd(), font) > width && rest.trimEnd().length > 1) {
            let n = rest.trimEnd().length - 1;
            while (n > 1 && g.measureText(rest.slice(0, n), font) > width)
                n--;
            lines.push(rest.slice(0, n));
            rest = rest.slice(n);
        }
        line = rest;
    }
    if (line.trim())
        lines.push(line.trimEnd());
    return lines;
}
const wrap = wrapText;

/** As much of `text` as fits in `width` with "…" after it, cut by characters (`.byTruncatingTail`). */
function fitTail(g, text, font, width) {
    let low = 0, high = text.length;
    while (low < high) {
        const middle = Math.ceil((low + high) / 2);
        if (g.measureText(`${text.slice(0, middle).trimEnd()}…`, font) <= width)
            low = middle;
        else
            high = middle - 1;
    }
    return `${text.slice(0, low).trimEnd()}…`;
}

/**
 * At most `max` lines (`.lineLimit(max)`): past them, the last line is the rest
 * of the text from where it starts, cut by characters to the width with "…".
 */
function clampLines(g, text, font, width, max) {
    const lines = wrap(g, text, font, width);
    if (lines.length <= max)
        return lines;
    let rest = String(text);
    for (const line of lines.slice(0, max - 1))
        rest = rest.slice(line.length).replace(/^\s+/, '');
    lines.length = max;
    lines[max - 1] = fitTail(g, rest, font, width);
    return lines;
}

/**
 * A file's name in two lines at most, cut in the middle as Finder cuts it: the
 * start, an ellipsis, and the last word — "Снимок экра… 12.41.png" — so the end
 * that tells two screenshots apart stays (`ShelfTileName.fitted`).
 */
export function fittedTileName(g, name, width = TILE) {
    const fits = text => wrap(g, text, F.name, width).length <= 2;
    if (fits(name))
        return name;
    const space = name.lastIndexOf(' ');
    const tail = space < 0 ? name.slice(-8) : name.slice(space + 1);
    const joint = space < 0 ? '…' : '… ';
    const room = name.length - tail.length;
    let low = 0, high = Math.max(room - 1, 0);
    while (low < high) {
        const middle = Math.ceil((low + high) / 2);
        if (fits(name.slice(0, middle) + joint + tail))
            low = middle;
        else
            high = middle - 1;
    }
    return name.slice(0, low).trim() + joint + tail;
}

function paragraph(g, lines, cx, top, font, color, pitch) {
    lines.forEach((line, i) => g.drawText(line, cx, top + i * pitch, font, color, {align: 'center'}));
}

// MARK: - The tiles

function drawTile(g, scene, x, y, item, thumbnail, m) {
    const hovered = scene.pointerIn(x, y, TILE, ROW_H);
    const missing = item.missing;
    const px = x, py = y; // the preview's box, 76 square

    if (missing) {
        g.dashedRoundRect(px, py, TILE, TILE, 12, [1, 1, 1, 0x40 / 255], 1, [3, 3]);
        pageGlyph(g, px + 23, py + 19, 30, 38, [1, 1, 1, 0.18]);
        // Said on the file itself, where the eye looks for it.
        paragraph(g, t('File\nmoved').split('\n'), px + TILE / 2, py + TILE / 2 - 13, F.moved, Colors.orange, 13);
    } else {
        g.fillRoundRect(px, py, TILE, TILE, 12, [1, 1, 1, 0x1F / 255]);
        if (item.kind === 'image' && thumbnail) {
            g.clipped(() => g.roundRectPath(px + 10, py + 19, 56, 38, 5), () => g.drawImage(thumbnail, px + 10, py + 19, 56, 38));
            g.strokeRoundRect(px + 10.5, py + 19.5, 55, 37, 4.5, [1, 1, 1, 0.2], 1);
        } else {
            const gx = px + 23, gy = py + 19;
            pageGlyph(g, gx, gy, 30, 38, [1, 1, 1, 0.92]);
            if (item.badge) {
                const bw = g.measureText(item.badge, F.badge) + 6;
                // The badge stands out of the page's lower left: five in from its edge, four up from its foot.
                const bx = gx - 5, by = gy + 38 + 7 - 11;
                g.fillRoundRect(bx, by, bw, 11, 3, KIND_COLOUR[item.kind] ?? GREY);
                g.drawText(item.badge, bx + 3, by + (11 - g.lineHeight(F.badge)) / 2, F.badge, Colors.white);
            }
        }
    }

    // Two lines of 13 for the name, cut in the middle across both.
    const shown = fittedTileName(g, item.name);
    const lines = wrap(g, shown, F.name, TILE);
    paragraph(g, lines.slice(0, 2), x + TILE / 2, y + TILE + 6, F.name, missing ? [1, 1, 1, 0x59 / 255] : Colors.white, 13);

    if (missing) {
        // Nothing to drag; still heard, as moved (`isMissing ? "%@, moved" : item.name`).
        scene.addLabel?.({id: `tile:${item.id}`, x, y, w: TILE, h: ROW_H, label: t('%@, moved', item.name)});
    } else {
        scene.addHit({
            id: `tile:${item.id}`, x: px, y: py, w: TILE, h: TILE, label: item.name,
            // Past three points a drag starts, as a drag from Finder does.
            onDrag: (x, y, phase) => dragTile(scene, item, x, y, phase),
        });
    }
    if (hovered) {
        removeButton(g, scene, `remove:${item.id}`, px + TILE - 9 + 5, py + 9 - 5,
            () => m.call('remove', {id: item.id}), t('Remove %@ from the Shelf', item.name));
    }
}

const drags = new WeakMap();

function dragTile(scene, item, x, y, phase) {
    let d = drags.get(scene);
    if (phase === 'began') {
        drags.set(scene, {x, y, item, started: false});
    } else if (phase === 'changed' && d && !d.started && Math.hypot(x - d.x, y - d.y) > 3) {
        d.started = true;
        startDrag(scene, d.item);
    } else if (phase === 'ended') {
        drags.delete(scene);
        // Finder moves a file a moment after the drop; look again once it has.
        if (d?.started) {
            const timer = setTimeout(() => refreshAvailability(scene), AFTER_DRAG_MS);
            timer?.unref?.();
        }
    }
}

function startDrag(scene, item) {
    scene.actions.call?.('shelf', 'dragFile', {id: item.id})
        .then(answer => { if (answer?.path) scene.actions.startFileDrag?.(answer.path, item); })
        .catch(() => {});
}

/** The most of a Clipping's text four lines of a card can show, with room to spare. */
const PREVIEW = 1000;

function drawClipping(g, scene, x, y, clipping, copied, m) {
    const hovered = scene.pointerIn(x, y, CARD.w, CARD.h);
    const id = `clipping:${clipping.id}`;
    // Lines and runs of space folded, so four lines show the most of it. Only the start can
    // show: a long text (up to 100 000 characters) measured whole on every frame held the
    // compositor for a quarter of a second a card.
    const shown = clipping.text.slice(0, PREVIEW).split(/\s+/).filter(Boolean).join(' ');
    // The card is the button's label, its ground and all; the ✕ is not.
    pressable(g, scene, id, () => {
        g.fillRoundRect(x, y, CARD.w, CARD.h, 12, [1, 1, 1, hovered ? 0x2E / 255 : 0x1F / 255]);
        const lines = clampLines(g, shown, F.clip, CARD.w - 20, 4);
        const lh = g.lineHeight(F.clip);
        lines.forEach((line, i) => g.drawText(line, x + 10, y + 10 + i * lh, F.clip, Colors.white, {maxWidth: CARD.w - 20}));
        const label = copied ? t('Copied') : clock(Date.parse(clipping.copiedAt) / 1000);
        const font = copied ? F.clipTimeBold : F.clipTime;
        g.drawText(label, x + 10, y + CARD.h - 10 - g.lineHeight(font), font, copied ? Colors.green : Colors.caption);
    });
    scene.addHit({
        id, x, y, w: CARD.w, h: CARD.h,
        onClick: () => m.call('copy', {id: clipping.id}), label: copied ? t('Copied') : shown,
        description: t('Puts it on the clipboard'),
    });
    if (hovered) {
        removeButton(g, scene, `removeClipping:${clipping.id}`, x + CARD.w - 9 + 5, y + 9 - 5,
            () => m.call('removeClipping', {id: clipping.id}), t('Remove from the Shelf'));
    }
}

// MARK: - The zones

/** The line under the title: what lands in the tab, or how to turn its intake on. */
function detailText(detail) {
    switch (detail.hint) {
    case 'filesLimit': return t('Up to 20 files. The Shelf empties when CapaTheNotch quits.');
    case 'screenshotsLimit': return t('Up to 20. The Shelf empties when CapaTheNotch quits.');
    case 'turnOnImages': return t('Turn on “Images and files from the clipboard” in Settings → Modules → Shelf.');
    case 'turnOnText': return t('Turn on text from the clipboard in Settings → Modules → Shelf.');
    case 'clippingsExpire': return t('Up to %d. Each goes after 24 hours, and all when CapaTheNotch quits.', detail.limit);
    case 'clippingsStay': return t('Up to %d. All go when CapaTheNotch quits.', detail.limit);
    default: return '';
    }
}

function titleText(key) {
    switch (key) {
    case 'dragFiles': return t('Drag files here to keep them at hand');
    case 'screenshotsWait': return t('Screenshots and images you copy wait here');
    default: return t('Text you copy can wait here');
    }
}

/**
 * Kapa, the title and its line in the page's one dashed zone. `drop` is the
 * zone held open for a file being carried over the surface: as the file comes
 * near the words go and Kapa grows to the dashes, eyes on the file and mouth
 * opening for it; let go, it eats it there.
 */
function drawZone(g, scene, ctx, x, y, w, title, detail, drop, view, awake) {
    const h = ZONE_H;
    const u = ui(scene);
    const kapaOn = ctx.showsKapa;
    const near = drop && (view.isDropNear || view.swallowedAt != null && view.showsDropArea) && kapaOn;
    // Under Reduce Motion Kapa is where it is going at once (`.animation(reduceMotion ? nil : …)`).
    if (scene.reduced)
        u.near.set(near ? 1 : 0);
    else
        u.near.to(near ? 1 : 0, 0.38, 0.72);
    const k = u.near.value;

    g.dashedRoundRect(x, y, w, h, 14, [1, 1, 1, drop ? 0xB3 / 255 : 0x40 / 255], 1.5, [4, 4]);

    // Without Kapa there is nothing to grow, and the words stay. The title wraps
    // at the zone's width; the detail too, two lines at most.
    const titleLines = wrap(g, title, F.zoneTitle, w);
    const detailLines = clampLines(g, detail, F.zoneDetail, w, 2);
    const slot = drop ? REST_SIZE : kapaOn ? REST_SIZE : 22;
    const tl = g.lineHeight(F.zoneTitle), dl = g.lineHeight(F.zoneDetail);
    const total = slot + 6 + titleLines.length * tl + 6 + detailLines.length * dl;
    const top = y + (h - total) / 2;
    const cx = x + w / 2;
    g.withAlpha(1 - k, () => {
        paragraph(g, titleLines, cx, top + slot + 6, F.zoneTitle, Colors.white, tl);
        paragraph(g, detailLines, cx, top + slot + 6 + titleLines.length * tl + 6, F.zoneDetail, Colors.caption, dl);
    });

    const restX = cx, restY = top + REST_SIZE / 2;
    if (kapaOn) {
        const size = REST_SIZE + (NEAR_SIZE - REST_SIZE) * k;
        const kx = restX + (cx - restX) * k, ky = restY + (y + h / 2 - restY) * k;
        if (drop) {
            // Drawn at its close-up size and scaled down at rest, so it grows without
            // being drawn anew; the gulp starts once for each drop (its time is its identity).
            const swallowedAt = view.showsDropArea && view.swallowedAt != null ? view.swallowedAt : undefined;
            ctx.drawKapa(g, 'shelf-drop', kx - size / 2, ky - size / 2, size, 'dropReady',
                {awake, drawnAt: NEAR_SIZE, showsBadge: false, swallowedAt});
        } else {
            // Nothing is drawn over her room after her: she may have a layer of her own.
            ctx.drawKapa(g, 'shelf-empty', kx - size / 2, ky - size / 2, size, 'curious', {awake, layer: true});
        }
    } else {
        dropGlyph(g, cx - 11, top + (slot - 22) / 2, drop ? Colors.white : Colors.caption);
    }
    return {x, y, w, h};
}

// MARK: - The page

export function drawPage(g, scene, box, ctx) {
    const m = ctx.module;
    if (!m?.view)
        return;
    observe(scene, ctx);
    const view = m.view;
    const call = (method, args) => scene.actions.call?.('shelf', method, args);
    const model = {call};
    const u = ui(scene);
    const tab = view.tab;
    const awake = isVisible(scene, ctx);
    const x0 = box.x + 18, W = box.width - 36, top = box.y + 10;

    if (u.tab !== tab) {
        u.tab = tab;
        u.scroll[tab] = 0;
    }
    const items = tab === 'clipboard' ? view.clippings : view[tab];
    const held = items.length;

    drawHeader(g, scene, ctx, m, view, x0, top, W, held, u, model, awake);

    const contentTop = top + 18 + 12;
    scene.scrollableRow = null;
    scene.shelfDropArea = null;
    if (view.showsDropArea) {
        // The row is gone while the zone stands in its place; it comes back from its start.
        u.scroll[tab] = 0;
        scene.shelfDropArea = drawZone(g, scene, ctx, x0, contentTop, W, t('Drag files here to keep them at hand'),
            t('Up to 20 files. The Shelf empties when CapaTheNotch quits.'), true, view, awake);
        return;
    }
    u.near.set(0);
    if (held === 0) {
        u.scroll[tab] = 0;
        const info = view.tabs.find(tabView => tabView.tab === tab);
        drawZone(g, scene, ctx, x0, contentTop, W, titleText(info.emptyTitle), detailText(info.emptyDetail), false, view, awake);
        return;
    }
    drawRow(g, scene, ctx, m, view, x0, contentTop, W, tab, items, u, model);
}

function drawHeader(g, scene, ctx, m, view, x0, top, W, held, u, model, awake) {
    const tab = view.tab;
    // Kapa for a moment after something lands, gone with the drop area. While it
    // stands in the row, 22 high on the baseline, the row's left side and Clear
    // rise with it (`HStack(alignment: .firstTextBaseline)` in a frame of 18).
    const alpha = ctx.showsKapa && !view.showsDropArea ? landedAlpha(u, wall()) : 0;
    const rise = LANDED_RISE * alpha;
    // Baselines of the left side line up; the row is 18 high and its line 19.5.
    const baseline = top + (18 - 19.5) / 2 + F.title.size * 1.005 - rise;
    const topFor = font => baseline - font.size * 1.005;

    g.drawText(t('Shelf'), x0, topFor(F.title), F.title, Colors.white);
    const titleW = g.measureText(t('Shelf'), F.title);
    const count = held === 0 ? t('Empty') : m.counts?.[tab] ?? String(held);
    g.drawText(count, x0 + titleW + 8, topFor(F.count), F.count, Colors.caption);
    const countW = g.measureText(count, F.count);

    if (alpha > 0) {
        const group = g.group ?? g.withAlpha;
        group.call(g, alpha, () => ctx.drawKapa(g, 'shelf-landed', x0 + titleW + 8 + countW + 8, baseline - 4 - 11, 22, 'received', {awake}));
    }
    // Frames while the fade moves, in and out; held at 1 between, one frame
    // at the 1.8 seconds it starts out (`landedAlpha`).
    const age = wall() - u.landedAt;
    if (ctx.showsKapa && age < 2.0) {
        if (age >= 0.15 && age < 1.8)
            scene.wantFrameAt(scene.now + 1.8 - age);
        else
            scene.wantFrame();
    }

    // Red while there is something to clear; grey, and doing nothing, while the tab is empty.
    const clear = t('Clear');
    const clearW = g.measureText(clear, F.clear);
    // Disabled, it is never held down.
    pressable(g, scene, 'shelf-clear', () =>
        g.drawText(clear, x0 + W - clearW, topFor(F.clear), F.clear, held === 0 ? Colors.caption : Colors.red));
    if (held > 0) {
        scene.addHit({
            id: 'shelf-clear', x: x0 + W - clearW - 4, y: top, w: clearW + 8, h: 18,
            onClick: () => model.call('clear'), label: t('Clear %@', t(TAB_TITLE[tab])),
        });
    }

    // The tabs, in the middle of the page whatever the two sides measure.
    const widths = TABS.map(id => g.measureText(t(TAB_TITLE[id]), F.tab));
    const total = widths.reduce((a, b) => a + b, 0) + 8 * (TABS.length - 1);
    let x = x0 + W / 2 - total / 2;
    TABS.forEach((id, i) => {
        const label = t(TAB_TITLE[id]);
        pressable(g, scene, `tab:${id}`, () => g.drawText(label, x, top + 0.05 + 1, F.tab, id === tab ? Colors.white : Colors.caption));
        scene.addHit({
            id: `tab:${id}`, x: x - 4, y: top, w: widths[i] + 8, h: 18,
            onClick: () => model.call('setTab', {tab: id}), label, selected: id === tab,
        });
        x += widths[i] + 8;
    });
}

function drawRow(g, scene, ctx, m, view, x0, rowTop, W, tab, items, u, model) {
    const isClip = tab === 'clipboard';
    const itemW = isClip ? CARD.w : TILE;
    const n = items.length;
    // Room for the ✕ that stands out of a tile's corner is taken from the gap
    // above the row; and six of trailing room, as the drawing leaves.
    const content = n * itemW + Math.max(n - 1, 0) * GAP + 6;
    const overflow = content > W;
    const max = Math.max(0, content - W);
    u.scroll[tab] = Math.min(Math.max(u.scroll[tab], 0), max);
    // The row is the page's to scroll only while it can be seen (`claimRow`): a
    // swipe elsewhere turns the page.
    if (overflow && ctx.visible) {
        scene.scrollableRow = {
            x: x0, y: rowTop - 6, w: W, h: ROW_H + 6,
            scrollBy: dx => { u.scroll[tab] = Math.min(Math.max(u.scroll[tab] - dx, 0), max); },
        };
    }
    const clip = cr => cr.rectangle(x0, rowTop - 6, W, ROW_H + 6);
    g.clipped(clip, () => {
        items.forEach((item, i) => {
            const x = x0 + i * (itemW + GAP) - u.scroll[tab];
            if (x > x0 + W || x + itemW < x0)
                return;
            if (isClip)
                drawClipping(g, scene, x, rowTop, item, view.justCopied === item.id, model);
            else
                drawTile(g, scene, x, rowTop, item, thumbnailFor(scene, m, item), model);
        });
    });
}

function thumbnailFor(scene, m, item) {
    const path = m.thumbnails?.[item.id];
    return path && item.hasThumbnail ? scene.images.get(path, item.id) : null;
}

export default {
    id: 'shelf',
    page: 'shelf',
    drawPage,

    /**
     * Called by the scene as state arrives (`setModel`) and at the start of every
     * draw, whether or not the page is drawn: a landing, and the page coming into view.
     */
    observe,

    /** While the Shelf holds a Clipping the surface is kept out of screen capture (ADR 0005). */
    excludesFromCapture: ctx => !!ctx.module?.holdsClippings,

    /** The hub asks the surface to write a Clipping to the clipboard; the surface owns it. */
    onEvent(scene, name, data) {
        if (name === 'copyText')
            scene.actions.writeClipboard?.(data.text);
    },
};
