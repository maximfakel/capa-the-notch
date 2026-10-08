// The Capacity page: one card per Provider that is on, or the three marks and
// a way to Settings while none is. `DetailCapacityView`, `ProviderCard`,
// `NothingConnectedView` and `ConnectAction` in NotchRootView.swift.

import {Colors, Metrics, Type} from '../metrics.js';
import {drawMark} from '../../marks.js';
import {
    PRESSED_OPACITY, capsuleButton, capsuleWidth, drawGauge, drawParagraph, isPressed, refreshGlyph, resetCountdown,
} from '../widgets.js';
import {dayMonth} from '../format.js';
import {t} from '../strings.js';


/** What the card's chip says, and in what colour (`ProviderCard.chip`). */
export function chipFor(view, wide) {
    if (view.state === 'disconnected' && view.needsAPersonFirst)
        return {text: t('No data'), color: Colors.red};
    // OpenCode's month used up stops work however green the windows are, so it
    // takes the chip's place, in red. A half-width card has room only for the short form.
    if (view.monthUsedUp) {
        if (!wide || !view.monthUsedUp.until)
            return {text: t('Month used up'), color: Colors.red};
        return {text: t('Monthly limit reached · until %@', dayMonth(view.monthUsedUp.until)), color: Colors.red};
    }
    switch (view.state) {
    case 'mock': return {text: t('Mock'), color: Colors.caption};
    case 'connecting': return {text: t('Connecting'), color: Colors.caption};
    case 'fresh': return {text: t('Fresh'), color: Colors.green};
    case 'stale': return {text: t('Stale'), color: Colors.yellow};
    default: return {text: '—', color: Colors.red};
    }
}

/**
 * @param g the Gfx; @param scene the SurfaceScene (hits, hover); @param box {x, y, width}
 * @param model what the page draws: `providers`, `highlighted`, `kapa`, callbacks
 */
export function drawCapacityPage(g, scene, box, model) {
    const offered = offeredMarks(model);
    if (offered.length) {
        drawNothingConnected(g, scene, box, model, offered);
        return;
    }
    // Nothing known yet is not nothing connected: no cards, and no way to Settings either.
    const shown = model.providers.filter(p => !p.switchedOff);
    if (shown.length === 0)
        return;
    // One Kapa a page, on the card whose state it shows (ADR 0006).
    const focus = model.showsKapa ? model.capacityFocus(shown) : null;
    const margin = Metrics.pageMargin, gap = 12;
    const cardW = (box.width - 2 * margin - gap * (shown.length - 1)) / shown.length;
    // When the gaps' words are worked out for: now, every time the page is drawn.
    const now = Date.now() / 1000;
    shown.forEach((view, i) => {
        drawCard(g, scene, {
            x: box.x + margin + i * (cardW + gap), y: box.y, width: cardW, height: Metrics.pageHeight,
        }, view, shown.length === 1, model, focus?.provider === view.provider ? focus.expression : null, now);
    });
}

/**
 * The Providers whose marks stand over the way to Settings: every one while
 * there are Providers and none is on, and none otherwise — nothing known yet
 * is not nothing connected (`SurfaceCards.offered`).
 */
export function offeredMarks(model) {
    if (model.offered)
        return model.offered;
    const all = model.providers;
    return all.length && all.every(p => p.switchedOff) ? all : [];
}

/** Whether Kapa on this page is on screen: the surface open, and this page chosen or a swipe under way. */
function kapaAwake(model) {
    return !!model.expanded && (model.selectedPage === 'capacity' || (model.scene?.travel ?? 0) !== 0);
}

function drawCard(g, scene, c, view, wide, model, kapa, now) {
    const pad = Metrics.cardPadding;
    g.fillRoundRect(c.x, c.y, c.width, c.height, Metrics.cardRadius, Colors.card);
    // The card is heard as a whole first, its buttons and gauges in it (`CapacitySpeech.provider`).
    scene.addLabel?.({id: `card:${view.provider}`, x: c.x, y: c.y, w: c.width, h: c.height, label: view.spoken});

    // Header: the mark, the name, then — at the far end — the chip and the refresh button.
    const rowTop = c.y + pad;
    const rowH = Metrics.headerRow;
    const markSize = 17;
    g.save();
    g.translate(c.x + pad, rowTop + (rowH - markSize) / 2);
    drawMark(g.cr, view.provider, markSize, g.alpha);
    g.restore();
    const nameFont = Type.providerName;
    const nameX = c.x + pad + markSize + 6;
    const nameW = g.drawText(view.name, nameX, rowTop + (rowH - g.lineHeight(nameFont)) / 2, nameFont, Colors.white);

    // The refresh button: the glyph in a 14 × 22 frame, which is all it answers to.
    const refreshW = 14, refreshH = 22;
    const refreshX = c.x + c.width - pad - refreshW;
    const refreshY = rowTop + (rowH - refreshH) / 2;
    const refreshId = `refresh:${view.provider}`;
    // Held down, the glyph dims as one picture: its head over the arc's end no darker than either.
    g.group(isPressed(scene, refreshId) ? PRESSED_OPACITY : 1,
        () => refreshGlyph(g, refreshX + refreshW / 2, rowTop + rowH / 2, Colors.white));
    scene.addHit({
        id: refreshId, x: refreshX, y: refreshY, w: refreshW, h: refreshH,
        onClick: () => model.refresh(view.provider), cursor: 'pointer', label: t('Refresh %@ Capacity', view.name),
        focusable: true,
    });

    // The chip is measured first: what it says outranks Kapa. Short of room it
    // shrinks to 85% before it gives out (`.minimumScaleFactor(0.85)`).
    const chip = chipFor(view, wide);
    const chipRight = refreshX - 6;
    const chipRoom = Math.max(chipRight - (nameX + nameW + 12), 0);
    const chipFullW = g.measureText(chip.text, Type.statusChip);
    const chipScale = chipFullW > chipRoom ? Math.max(chipRoom / chipFullW, 0.85) : 1;
    const chipFont = chipScale === 1 ? Type.statusChip : {...Type.statusChip, size: Type.statusChip.size * chipScale};
    const chipW = g.drawText(chip.text, chipRight, rowTop + (rowH - g.lineHeight(chipFont)) / 2, chipFont, chip.color,
        {align: 'right', maxWidth: chipRoom});

    // Kapa beside the name while there is room for both, smaller where there is
    // little, and gone where there is none: the name is what has to stay.
    if (kapa) {
        const room = chipRight - chipW - 12 - (nameX + nameW);
        const size = room >= 6 + 26 ? 26 : room >= 3 + 20 ? 20 : 0;
        if (size) {
            const gap = size === 26 ? 6 : 3;
            // Nothing is drawn over her room after her: she may have a layer of her own.
            model.drawKapa(g, `capacity-card:${view.provider}:${size}`, nameX + nameW + gap, rowTop + (rowH - size) / 2, size, kapa,
                {awake: kapaAwake(model), showsBadge: true, layer: true});
        }
    }

    const bodyX = c.x + pad;
    const bodyW = c.width - 2 * pad;
    const guidanceFont = Type.guidance;

    if (view.state === 'disconnected') {
        // A Provider that cannot be read: twenty above what is offered and
        // six under it ("Notch — Disconnected").
        const top = rowTop + rowH + 20;
        if (view.needsAPersonFirst)
            drawParagraph(g, view.guidance, bodyX, top, guidanceFont, Colors.caption, bodyW, 2);
        else {
            // The button stands in the middle of the card's width (`.frame(maxWidth: .infinity)`).
            const label = t('Connect');
            capsuleButton(g, scene, `connect:${view.provider}`, label, bodyX + (bodyW - capsuleWidth(g, label, 12)) / 2, top, 12,
                () => model.connect(view.provider), {label: t('Connect this Provider'), focusable: true});
        }
        return;
    }
    if (view.windows.length === 0 && view.guidance && !view.reasonRepeatsTheChip) {
        drawParagraph(g, view.guidance, bodyX, rowTop + rowH + 10, guidanceFont, Colors.caption, bodyW, 2);
        return;
    }

    const windows = view.windows.length ? view.windows : [null, null];
    const top = rowTop + rowH + 10;

    // Old numbers are shown, but not as if they were new; places still empty are not dimmed.
    // The gauges fade as one picture: where an arc crosses its track, no darker than either.
    const dim = view.state === 'stale' && view.windows.length ? 0.5 : 1;
    // Each gauge is heard as its window, and one not read yet as the card's chip (`CapacityGauge.placeholder`).
    const said = (w, i, x) => scene.addLabel?.({
        id: `gauge:${view.provider}:${w?.id ?? i}`, x, y: top, w: Metrics.gaugeSize, h: Metrics.gaugeSize,
        label: w ? w.spoken : chip.text,
    });
    g.group(dim, () => {
        const n = windows.length;
        if (wide) {
            const cell = (bodyW - 8 * (n - 1)) / n;
            windows.forEach((w, i) => {
                const x = bodyX + i * (cell + 8);
                drawGauge(g, x, top, w, {showsLabel: false, highlighted: isHighlighted(model, view, w), now});
                said(w, i, x);
                if (w)
                    drawWideDetail(g, x + Metrics.gaugeSize + 14, top, w, cell - Metrics.gaugeSize - 14, now);
            });
        } else {
            const cell = bodyW / n;
            windows.forEach((w, i) => {
                const x = bodyX + i * cell + (cell - Metrics.gaugeSize) / 2;
                drawGauge(g, x, top, w, {showsLabel: true, highlighted: isHighlighted(model, view, w), now});
                said(w, i, x);
            });
        }
    });
}

function isHighlighted(model, view, w) {
    return !!w && model.highlighted && model.highlighted.provider === view.provider && model.highlighted.windowId === w.id;
}

/** Beside a wide card's gauge: the window's name, how much is used, and how long until it comes back. */
function drawWideDetail(g, x, gaugeTop, w, maxWidth, now) {
    const nameFont = Type.geist(13), capFont = Type.caption;
    const lines = [
        {s: w.label, font: nameFont, color: [1, 1, 1, 0.75]},
        {s: t('%d%% used', w.usedPercentage ?? Math.round((1 - w.remainingFraction) * 100)), font: capFont, color: Colors.caption},
    ];
    if (w.resetsAt != null)
        lines.push({s: t('resets in %@', resetCountdown(w.resetsAt, now)), font: capFont, color: Colors.caption});
    const total = lines.reduce((sum, l) => sum + g.lineHeight(l.font), 0) + 2 * (lines.length - 1);
    let y = gaugeTop + (Metrics.gaugeSize - total) / 2;
    for (const l of lines) {
        g.drawText(l.s, x, y, l.font, l.color, {maxWidth: Math.max(maxWidth, 0)});
        y += g.lineHeight(l.font) + 2;
    }
}

/** Nothing connected: every Provider's mark, a line, and one button to Settings. */
function drawNothingConnected(g, scene, box, model, providers) {
    const cx = box.x + box.width / 2;
    const markSize = 28, kapaSize = 30, spacing = 22;
    const withKapa = model.showsKapa;
    const rowW = (withKapa ? kapaSize + spacing : 0) + providers.length * markSize + (providers.length - 1) * spacing;
    const textFont = Type.geist(13, 500);
    const titleH = g.lineHeight(textFont);
    const buttonH = 38;
    // Kapa off is no Kapa at all (`WithKapa`): the row is only as tall as the marks.
    const rowH = withKapa ? kapaSize : markSize;
    const blockH = rowH + 14 + titleH + 14 + buttonH;
    // Centred in the page's 152, six points lower than the middle (`.padding(.top, 6)`).
    const top = box.y + (Metrics.pageHeight - blockH) / 2 + 3;

    let x = cx - rowW / 2;
    // The marks are heard as one, by their names (`.accessibilityElement(children: .combine)`).
    const names = providers.map(p => typeof p === 'string' ? model.providers.find(v => v.provider === p)?.name ?? p : p.name ?? p.provider);
    scene.addLabel?.({
        id: 'marks', x: x + (withKapa ? kapaSize + spacing : 0), y: top + (rowH - markSize) / 2,
        w: providers.length * markSize + (providers.length - 1) * spacing, h: markSize, label: names.join(', '),
    });
    if (withKapa) {
        // Nothing connected yet: the first thing Kapa does is say hello.
        model.drawKapa(g, 'hello', x, top + (rowH - kapaSize) / 2, kapaSize, 'hello', {awake: kapaAwake(model), layer: true});
        x += kapaSize + spacing;
    }
    for (const offered of providers) {
        g.save();
        g.translate(x, top + (rowH - markSize) / 2);
        drawMark(g.cr, typeof offered === 'string' ? offered : offered.provider, markSize, g.alpha);
        g.restore();
        x += markSize + spacing;
    }
    g.drawText(t('Connect up to two in Settings'), cx, top + rowH + 14, textFont, Colors.caption,
        {align: 'center', maxWidth: box.width - 2 * Metrics.pageMargin});
    const label = t('Open Settings');
    const w = capsuleWidth(g, label, 14);
    capsuleButton(g, scene, 'open-settings', label, cx - w / 2, top + rowH + 14 + titleH + 14, 14, () => model.openSettings(),
        {label: t('Open Provider Settings'), focusable: true});
}
