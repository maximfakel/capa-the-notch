// The Teleprompter Module on the surface: the Row under the closed strip and
// the open surface's page (`TeleprompterViews.swift`). Everything is drawn at
// the coordinates the SwiftUI implies; the numbers are in
// `teleprompter-layout.js`, equal to the Rust's.

import {Colors, Metrics, Type} from '../metrics.js';
import {t} from '../strings.js';
import {drawTransport} from './music-parts.js';
import {
    LINE_GAP, ROW_HEIGHT, ROW_WIDTH, STRIP_GAP, TEXT_INSET, TOP_INSET, clockText, elapsedAt, fadeOpacityAt, fadeStops,
    controlWidth, kern, lineHeight, linesToDraw, pitch, pointsOf, positionAt, previewHeight, progressAt, progressFillWidth, rowLines,
    speedText, steppedAt, textAreaHeight, lineOpacity, CONTROLS_WIDTH,
} from './teleprompter-layout.js';

const MODULE = 'teleprompter';
const call = (scene, method, args = null) => scene.actions.call?.(MODULE, method, args);

/** The font a line is set in: Geist Medium at the Script's size, a little tighter tracked. */
const scriptFont = size => ({size: pointsOf(size), weight: 500, kern: kern(size)});

const wall = () => Date.now();

// MARK: - Glyphs (SF Symbols' pause.fill, play.fill, stop.fill, minus, plus)

/** pause.fill or play.fill, the action a click would take, drawn as Music draws them. */
function actionGlyph(g, running, cx, cy, size, color) {
    drawTransport(g, running ? 'pause' : 'play', cx, cy, size, color);
}

/** stop.fill: a square about three quarters of the point size, its corners a sixth of its side. */
function stopGlyph(g, cx, cy, size, color) {
    const side = size * 0.74;
    g.fillRoundRect(cx - side / 2, cy - side / 2, side, side, side * 0.17, color);
}

function plusMinus(g, cx, cy, size, plus, color) {
    const arm = size * 0.36, w = size * 0.16;
    g.fillRoundRect(cx - arm, cy - w / 2, arm * 2, w, w / 2, color);
    if (plus)
        g.fillRoundRect(cx - w / 2, cy - arm, w, arm * 2, w / 2, color);
}

// MARK: - The Row under the closed strip

/**
 * Three lines or more under the strip, the current one on top and nearest the
 * camera, the next ones quieter; on the left a column that stays put while the
 * Script moves — pause while running and play otherwise, and Stop under it.
 */
function drawRow(g, scene, box, ctx) {
    const tp = ctx.module;
    const size = tp.textSize;
    const lh = lineHeight(size);
    const top = box.y + STRIP_GAP;
    const areaH = textAreaHeight(size);

    // On the host's layer the lines are drawn there, and only they, while nothing
    // else moves; the row's hits and its controls stay with the surface.
    if (!ctx.layer)
        drawLines(g, scene, box, ctx);

    // A click on the row, the gap under the strip included, pauses and
    // resumes; the controls are over it. A screen reader hears the state.
    scene.addHit({
        id: 'tp-row', x: box.x, y: box.y, w: ROW_WIDTH, h: STRIP_GAP + areaH, cursor: 'pointer',
        onClick: () => call(scene, 'toggle'), label: t(tp.spoken ?? `Teleprompter, ${tp.playback.state}`),
    });

    const cx = box.x + 18 + CONTROLS_WIDTH / 2;
    const running = tp.playback.state === 'running';
    const y1 = top + TOP_INSET, y2 = y1 + lh + LINE_GAP;
    actionGlyph(g, running, cx, y1 + lh / 2, 13, Colors.white);
    stopGlyph(g, cx, y2 + lh / 2, 14, Colors.red);
    scene.addHit({
        id: 'tp-row-toggle', x: box.x + 18, y: y1, w: CONTROLS_WIDTH, h: lh, cursor: 'pointer',
        onClick: () => call(scene, 'toggle'), label: t(running ? 'Pause' : 'Start'),
    });
    scene.addHit({
        id: 'tp-row-stop', x: box.x + 18, y: y2, w: CONTROLS_WIDTH, h: lh, cursor: 'pointer',
        onClick: () => call(scene, 'stop'), label: t('Stop'),
    });
}

/** The row's text area: where the lines are drawn, and all a layer of them holds. */
function linesRect(box, ctx) {
    return {x: box.x, y: box.y + STRIP_GAP, w: ROW_WIDTH, h: textAreaHeight(ctx.module.textSize)};
}

/**
 * The Script's lines in the row. Where they may go on the host's layer they are
 * drawn as one picture of their own in their area (`Gfx.isolated`), on the
 * surface as on the layer, so the two are the same to the last bit when one
 * hands them to the other. On the layer, the next frame is the layer's: every
 * frame while the Script glides, the next tick of its beat under Reduce Motion.
 */
function drawLines(g, scene, box, ctx) {
    const area = linesRect(box, ctx);
    if (scene.liveLayers)
        g.isolated(area.x, area.y, area.w, area.h, () => drawScript(g, scene, box, ctx));
    else
        drawScript(g, scene, box, ctx);
    const tp = ctx.module;
    if (ctx.layer && tp.playback.state === 'running')
        scene.wantFrameAt(scene.reduced ? scene.now + untilNextStep(tp, wall()) : scene.now);
}

function drawScript(g, scene, box, ctx) {
    const tp = ctx.module;
    const size = tp.textSize;
    const lh = lineHeight(size), p = pitch(size);
    const top = box.y + STRIP_GAP;
    const areaH = textAreaHeight(size);
    // Under Reduce Motion the Script moves a whole line at a time, on a
    // quarter-second beat; otherwise it glides.
    const reduced = scene.reduced;
    const position = positionAt(tp, reduced ? steppedAt(tp, wall()) : wall());
    const place = reduced ? Math.floor(position) : position;

    // The Script, clipped to its area and set through the fade: the lines drawn
    // once, at full white, on a picture of their own, laid down through the
    // gradient mask (`ScriptScrollView.layoutFade`), so a moving line brightens
    // and dims evenly through the two points between lines.
    const font = scriptFont(size);
    const cr = g.cr;
    const masked = !!(cr.pushGroup && cr.mask && cr.linearGradient);
    const stops = fadeStops(size);
    g.clipped(c => c.rectangle(box.x, top, ROW_WIDTH, areaH), () => {
        const range = linesToDraw(position, size, tp.lines.length);
        if (!range)
            return;
        if (masked)
            cr.pushGroup();
        try {
            for (let i = range[0]; i <= range[1]; i++) {
                const y = TOP_INSET - place * p + i * p; // from the area's top
                if (y + lh <= 0 || y >= areaH)
                    continue;
                // With nothing to mask with, each line at the fade where its middle is.
                const opacity = masked ? 1 : fadeOpacityAt(stops, y + lh / 2);
                g.drawText(tp.lines[i], box.x + TEXT_INSET, top + y, font, [1, 1, 1, opacity],
                    {maxWidth: ROW_WIDTH - TEXT_INSET - 18});
            }
        } finally {
            if (masked) {
                cr.popGroupToSource();
                cr.mask(fadeMask(cr, top, areaH, stops));
            }
        }
    });
}

/**
 * The fade as a mask: a vertical gradient down the text area, `top` to
 * `top + height`, whose alpha is the fade's `[y, opacity]` stops.
 */
function fadeMask(cr, top, height, stops) {
    return cr.linearGradient(0, top, 0, top + height,
        stops.map(([y, opacity]) => [Math.min(Math.max(y / height, 0), 1), 1, 1, 1, opacity]));
}

// MARK: - The expanded surface's page

/** Seconds from `wallMs` to the next tick of the beat `steppedAt` counts from the anchor. */
function untilNextStep(tp, wallMs, stepMs = 250) {
    const next = steppedAt(tp, wallMs, stepMs) + stepMs;
    return Math.max(next - wallMs, 1) / 1000;
}

const paste = async scene => {
    // The clipboard is read now, and only now: at the click.
    const text = await scene.actions.readClipboard?.();
    if (text && text.trim())
        call(scene, 'paste', {text});
};

/**
 * Paper "Notch — Expanded — Teleprompter": the current line and the next, the
 * progress to drag, the time read and left, and the controls — pause or play,
 * slower and faster, Paste, Edit Script.
 */
function drawPage(g, scene, box, ctx) {
    const tp = ctx.module;
    if (!tp)
        return;
    const size = tp.textSize;
    const lh = lineHeight(size);
    // The page's clock ticks four times a second while the Script runs (its
    // `TimelineView`): the line, the progress and the time move in steps.
    const now = steppedAt(tp, wall());
    const x = box.x + 18;
    const width = box.width - 36;
    const running = tp.playback.state === 'running';
    const position = positionAt(tp, now);
    const font = scriptFont(size);
    // The page is heard as the Script's state, its controls in it (`playback.state.spoken`).
    scene.addLabel?.({id: 'tp-page', x: box.x, y: box.y, w: box.width, h: Metrics.pageHeight,
        label: t(tp.spoken ?? `Teleprompter, ${tp.playback.state}`)});

    // The lines: current, next, the one after.
    let y = box.y + 10;
    if (tp.lines.length === 0) {
        // Geist Medium at the size, as the lines are, but not tracked tighter.
        g.drawText(t('Paste a Script, or write one in Settings.'), x, y, {size: pointsOf(size), weight: 500}, Colors.caption,
            {maxWidth: width});
    } else {
        const current = Math.min(Math.floor(position), Math.max(tp.lines.length - 1, 0));
        for (let i = 0; i < 3; i++) {
            const line = tp.lines[current + i];
            if (line !== undefined)
                g.drawText(line, x, y + i * (lh + LINE_GAP), font, [1, 1, 1, lineOpacity(i)], {maxWidth: width});
        }
    }
    y += previewHeight(size) + 14;

    // Progress: how far through the Script, drawn and dragged like a track's position.
    const fraction = scene.tpDrag ?? progressAt(tp, now);
    g.fillRoundRect(x, y, width, 4, 2, Colors.track);
    g.fillRoundRect(x, y, progressFillWidth(width, fraction), 4, 2, Colors.white);
    // Easier to catch than it is thick: six points round it (`.inset(by: -6)`).
    scene.addHit({
        id: 'tp-progress', x: x - 6, y: y - 6, w: width + 12, h: 4 + 12, cursor: 'pointer',
        onDrag: (px, _py, phase) => {
            const f = Math.min(Math.max((px - x) / width, 0), 1);
            if (phase === 'ended') {
                scene.tpDrag = null;
                call(scene, 'seek', {fraction: scene.tpDragLast ?? f});
                return;
            }
            scene.tpDrag = scene.tpDragLast = f;
        },
        label: t('Progress through the Script'),
    });
    const timeFont = Type.caption;
    const timeY = y + 4 + 7;
    g.drawText(clockText(elapsedAt(tp, now)), x, timeY + (14 - g.lineHeight(timeFont)) / 2, timeFont, Colors.caption);
    g.drawText(clockText(tp.playback.durationSeconds), x + width, timeY + (14 - g.lineHeight(timeFont)) / 2, timeFont, Colors.caption,
        {align: 'right'});
    y = timeY + 14 + 14;

    // Controls, 18 tall, eight apart, each as wide as its symbol.
    const mid = y + 9;
    const empty = tp.lines.length === 0;
    const actionW = controlWidth[running ? 'pause' : 'play'](14), stopW = controlWidth.stop(14);
    const minusW = controlWidth.minus(13), plusW = controlWidth.plus(13);
    let cx = x;
    g.withAlpha(empty ? 0.35 : 1, () => actionGlyph(g, running, cx + actionW / 2, mid, 14, Colors.white));
    if (!empty) {
        scene.addHit({
            id: 'tp-toggle', x: cx, y, w: actionW, h: 18, cursor: 'pointer', onClick: () => call(scene, 'toggle'),
            label: t(running ? 'Pause' : 'Start'),
        });
    }
    cx += actionW + 8;
    stopGlyph(g, cx + stopW / 2, mid, 14, Colors.red);
    scene.addHit({id: 'tp-stop', x: cx, y, w: stopW, h: 18, cursor: 'pointer', onClick: () => call(scene, 'stop'), label: t('Stop')});
    cx += stopW + 8;

    // Slower, the speed, faster: ten apart.
    plusMinus(g, cx + minusW / 2, mid, 13, false, Colors.caption);
    scene.addHit({id: 'tp-slower', x: cx - 3, y, w: minusW + 6, h: 18, cursor: 'pointer', onClick: () => call(scene, 'slower'), label: t('Slower')});
    cx += minusW + 10;
    // `.monospacedDigit()`: the figures keep their places as the speed changes.
    const speed = {...Type.geist(13, 600), tabular: true};
    const speedW = g.measureText(speedText(tp.playback.multiplier), speed);
    g.drawText(speedText(tp.playback.multiplier), cx, mid - g.lineHeight(speed) / 2, speed, Colors.white);
    scene.addLabel?.({id: 'tp-speed', x: cx, y, w: speedW, h: 18, label: t('Speed'),
        description: t('%.2f times').replace('%.2f', tp.playback.multiplier.toFixed(2))});
    cx += speedW + 10;
    plusMinus(g, cx + plusW / 2, mid, 13, true, Colors.caption);
    scene.addHit({id: 'tp-faster', x: cx - 3, y, w: plusW + 6, h: 18, cursor: 'pointer', onClick: () => call(scene, 'faster'), label: t('Faster')});
    cx += plusW + 8;

    // A still Kapa, never a moving one, on the page of the Module that reads by the camera (ADR 0006).
    if (ctx.showsKapa)
        ctx.drawKapa(g, 'teleprompter-page', cx + 6, mid - 11, 22, 'quiet', {awake: false});

    // Paste and Edit Script, sixteen apart, at the right edge.
    const textFont = Type.geist(13, 500);
    const editLabel = t('Edit Script'), pasteLabel = t('Paste');
    const editW = g.measureText(editLabel, textFont), pasteW = g.measureText(pasteLabel, textFont);
    const right = x + width;
    const textY = mid - g.lineHeight(textFont) / 2;
    g.drawText(editLabel, right, textY, textFont, Colors.caption, {align: 'right'});
    g.drawText(pasteLabel, right - editW - 16, textY, textFont, Colors.caption, {align: 'right'});
    scene.addHit({id: 'tp-edit', x: right - editW, y, w: editW, h: 18, cursor: 'pointer', onClick: () => scene.actions.openSettings?.('modules'), label: editLabel});
    scene.addHit({id: 'tp-paste', x: right - editW - 16 - pasteW, y, w: pasteW, h: 18, cursor: 'pointer', onClick: () => paste(scene), label: pasteLabel});
}

export default {
    id: MODULE,
    page: 'teleprompter',
    drawPage,

    compactRow(ctx) {
        const tp = ctx.module;
        if (!tp?.showingRow)
            return null;
        // Takes the music row's place — nearness to the camera is the point — and shows over a fullscreen application too.
        // Its lines are the row's moving part, which a host may draw on a layer of its own (`layer`).
        return {priority: 20, height: ROW_HEIGHT, width: ROW_WIDTH, wide: true, draw: drawRow, layer: {rect: linesRect, draw: drawLines}};
    },

    /** While the Script runs, a passing pointer does not open the surface over it; a click still does. */
    hoverOpens(ctx) {
        return ctx.module?.hoverOpens !== false;
    },

    running(ctx) {
        return ctx.module?.playback?.state === 'running';
    },

    /** A Script on screen is never shared (`TeleprompterSurface.excludedFromCapture`). */
    excludesFromCapture(ctx) {
        return !!ctx.module?.showingRow;
    },

    /**
     * A running Script moves by itself: the Row while closed, the page while it is
     * the one shown. Only the gliding Row moves every frame; the page, and the Row
     * under Reduce Motion, move on the quarter-second beat counted from the anchor
     * (`steppedAt`), so they ask for a frame at the next tick of it. With the lines
     * on the host's layer (`rowLayer`), the layer asks for its own frames.
     */
    needsFrames(ctx) {
        const tp = ctx.module;
        if (tp?.playback?.state !== 'running')
            return false;
        if (ctx.expanded ? ctx.selectedPage !== 'teleprompter' : !tp.showingRow || ctx.rowLayer)
            return false;
        if (!ctx.expanded && !ctx.scene?.reduced)
            return true;
        return {interval: untilNextStep(tp, wall())};
    },

    /** Two fingers on the Row: the Script follows them, and pauses. */
    onScroll(scene, ctx, dy) {
        const tp = ctx.module;
        if (!tp?.showingRow)
            return false;
        call(scene, 'moveByLines', {lines: dy / pitch(tp.textSize)});
        return true;
    },
};

export {rowLines};
