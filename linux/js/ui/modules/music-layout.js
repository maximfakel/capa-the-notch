// The Music Module's numbers, from Paper "Notch — Compact — Playing" and
// "Notch — Expanded — Playing" and the SwiftUI in MusicViews.swift. Pure: no
// drawing, so the layout is tested against what the Swift measures.

import {Metrics} from '../metrics.js';

export const MusicType = {
    title: {size: 15, weight: 500},
    artist: {size: 11, weight: 400},
    time: {size: 11, weight: 400},
    /** Six points under the strip, the artwork's 34, and 14 to the rounded edge. */
    rowHeight: 54,
    rowArtwork: 34,
    /** The page's height less the six points between the strip and it. */
    pageArtwork: Metrics.pageHeight - 6,
};

/** A symbol's drawn width at a point size: the SF Symbols' own proportions, to the pixel nearest. */
export const symbolWidth = {
    backward: size => size * 1.25,
    forward: size => size * 1.25,
    play: size => size * 0.9,
    pause: size => size * 0.9,
};

/** `MusicControls`: three buttons, eight apart, the middle one the larger. */
export function controlsWidth(small, large) {
    return symbolWidth.backward(small) + 8 + symbolWidth.play(large) + 8 + symbolWidth.forward(small);
}

export const EQUALIZER = {count: 7, barWidth: 2, pitch: 5, width: 32, rest: 4, beat: 0.3, minScale: 0.3, alpha: 0x8C / 255};

/** `CompactMusicRow`: where everything stands in a row `width` wide whose top is `y`. */
export function rowLayout(width, x, y, {kapa}) {
    const small = 10, large = 14;
    const controls = controlsWidth(small, large);
    const effect = 32; // Kapa 32, or the bars' 32 width
    const rightWidth = controls + 20 + effect;
    const left = x + 18;
    const top = y + 6;
    const rightX = x + width - 18 - rightWidth;
    const textX = left + MusicType.rowArtwork + 8;
    return {
        artwork: {x: left, y: top, size: MusicType.rowArtwork},
        text: {x: textX, width: Math.max(0, rightX - 20 - textX), top, height: 34},
        controls: {x: rightX, centerY: top + 17, small, large, width: controls},
        effect: kapa
            ? {x: rightX + controls + 20, y: top + (34 - effect) / 2, size: 32}
            : {x: rightX + controls + 20, y: top + 2, height: 30},
    };
}

/** `MusicPage`: the page's artwork, text column and the three rows in it. `y` is the page's top. */
export function pageLayout(width, x, y, {kapa}) {
    const art = MusicType.pageArtwork;
    const artX = x + 18, artY = y + 6;
    const colX = artX + art + 20;
    const colWidth = x + width - 18 - colX;
    const colTop = artY + (art - 121) / 2; // the column is 121 tall, centred against the artwork
    const effectWidth = kapa ? 40 : 32;
    const barY = colTop + 34 + 20;
    const controlsTop = barY + 4 + 7 + 14 + 20; // the bar, seven, the times, twenty
    const volumeBarX = colX + colWidth - 88;
    return {
        artwork: {x: artX, y: artY, size: art},
        column: {x: colX, width: colWidth, top: colTop},
        text: {x: colX, width: colWidth - 20 - effectWidth, top: colTop, height: 34},
        effect: kapa
            ? {x: colX + colWidth - 40, y: colTop + (34 - 40) / 2, size: 40}
            : {x: colX + colWidth - 32, y: colTop, height: 34},
        progress: {x: colX, y: barY, width: colWidth, height: 4, timesY: barY + 4 + 7},
        controls: {x: colX, top: controlsTop, height: 22, small: 14, large: 18},
        volume: {barX: volumeBarX, barY: controlsTop + 11 - 2, button: {x: volumeBarX - 8 - 18, y: controlsTop, width: 18, height: 22}},
    };
}

/** `MusicIdlePage`: the artwork or the quiet square, and the column of words. `y` is the page's top. */
export function idleLayout(width, x, y, {remembered}) {
    const art = MusicType.pageArtwork;
    const artX = x + 18, artY = y + 6;
    const colX = artX + art + 20;
    const colWidth = x + width - 18 - colX;
    return {artwork: {x: artX, y: artY, size: art}, column: {x: colX, width: colWidth, top: artY + (art - 121) / 2, height: 121}, remembered};
}
