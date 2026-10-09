// The Music Module on the surface: a row under the closed strip while a track
// plays, and a page on the open one. `CompactMusicRow`, `MusicPage`,
// `MusicIdlePage` and their parts in MusicViews.swift, at the Swift's
// coordinates. The state is the hub's `state.modules.music` (linux/crates/music).

import {Colors, Metrics, Type} from '../metrics.js';
import {clock} from '../format.js';
import {musicMood} from '../kapa/index.js';
import {t} from '../strings.js';
import {EQUALIZER, MusicType, controlsWidth, idleLayout, pageLayout, rowLayout, symbolWidth} from './music-layout.js';
import {Bars, drawNote, drawSpeaker, drawTransport} from './music-parts.js';
import {Progress, readingKey} from './music-progress.js';
import {PRESSED_OPACITY, isPressed} from '../widgets.js';

const MODULE = 'music';
const SECONDARY = Colors.caption;
const WHITE = Colors.white;

// MARK: - State that outlives a frame

const images = new Map(); // id -> {handle} once read, {handle: null} when it could not be
const asked = new Set();
/** The ids the state still names: everything else is freed (`prune`). */
let wanted = new Set();
let prunedFor;
/**
 * The last cover drawn, held in its place while the next one is read and
 * decoded, for up to the same two seconds `MusicPresence` holds a cover for a
 * track that has none yet: the Swift has the new picture at once, so nothing
 * blinks between them there, and nothing may here. `since` is when the wait began.
 */
let held = null; // {id, handle, since}
const HOLD_MS = 2000;

/** What one surface keeps between frames (`scene.moduleUi`): each surface has its own bar, bars and beat. */
function uiOf(scene) {
    const kept = scene.moduleUi ??= {};
    return kept[MODULE] ??= {
        progress: new Progress(),
        bars: {row: new Bars(30, 7), page: new Bars(34, 11)},
        /** Whether this surface asked for the volume to be watched. */
        watching: false,
        volumeSent: {at: 0, level: null},
        /** The level under the finger while the volume bar is dragged, and a moment after (`drawVolume`). */
        volumeDrag: null,
        /**
         * The page's one-second timeline (`TimelineView(.periodic(from: .now, by: 1))`):
         * where it started, on the scene's clock and the machine's, and the last
         * moment the bar was drawn for, which a new reading or a drag moves on.
         */
        beat: {since: null, sinceMs: 0, playing: false, changedMs: 0, key: null},
    };
}

const call = (scene, method, args) => scene.actions.call?.(MODULE, method, args)?.catch?.(e => console.error(`music.${method}: ${e}`));

/** A frame at `at` (the scene's seconds): the next beat, not the next frame. */
function frameAt(scene, at) {
    if (scene.wantFrameAt)
        scene.wantFrameAt(at);
    else
        scene.kapaDue = Math.min(scene.kapaDue, at);
}

/** A decoded picture's memory goes back now, not when the collector comes. */
function free(handle) {
    try {
        handle?.finish?.();
        handle?.$dispose?.();
    } catch {
        // Already gone.
    }
}

/** Keeps only the pictures of the tracks shown, loaded and remembered; frees the rest. */
function prune(state) {
    if (state === prunedFor)
        return;
    prunedFor = state;
    const tracks = [state?.shown, state?.loaded, state?.remembered?.track];
    wanted = new Set(tracks.flatMap(t => [t?.artworkId, t?.iconId]).filter(Boolean));
    for (const [id, known] of images) {
        if (!wanted.has(id) && id !== held?.id) {
            free(known.handle);
            images.delete(id);
        }
    }
    for (const id of asked) {
        if (!wanted.has(id))
            asked.delete(id);
    }
}

/** A cover or an icon by its id, if it has arrived; asks for it the first time. */
function imageOf(scene, id) {
    if (!id)
        return null;
    const known = images.get(id);
    if (known)
        return known.handle;
    if (!asked.has(id)) {
        asked.add(id);
        wanted.add(id);
        Promise.resolve(call(scene, 'artwork', {id}))
            .then(answer => (answer?.png ? scene.actions.decodeImage?.(answer.png) : null))
            .then(handle => {
                // A picture that arrives for a track no longer shown is not kept.
                if (!wanted.has(id) || !asked.has(id)) {
                    free(handle);
                    return;
                }
                images.set(id, {handle: handle ?? null});
                scene.onChange();
            })
            .catch(() => {
                if (asked.has(id))
                    images.set(id, {handle: null});
            });
    }
    return null;
}

/** The cover just drawn becomes the one held; the one held before it goes, unless the state still names it. */
function hold(id) {
    if (held?.id === id)
        return;
    const before = held;
    held = {id, handle: images.get(id)?.handle ?? null, since: null};
    if (before && !wanted.has(before.id) && images.has(before.id)) {
        free(images.get(before.id).handle);
        images.delete(before.id);
    }
}

/**
 * The cover held for `id` while it is on its way: only when a cover is
 * coming (an id asked for, not yet read), and for two seconds from when the
 * wait began; a frame is asked for at their end, so the ground follows on time.
 */
function heldFor(scene, id) {
    if (!held?.handle || !id || id === held.id || images.has(id))
        return null;
    const now = Date.now();
    held.since ??= now;
    const left = HOLD_MS - (now - held.since);
    if (left <= 0)
        return null;
    frameAt(scene, scene.now + left / 1000);
    return held.handle;
}

// MARK: - Pieces

/**
 * `MusicArtwork`: the track's artwork, or — when the source has sent none —
 * the icon of the application playing it at six tenths of the size, on a
 * quiet ground; with no icon, the ground alone.
 */
function drawArtwork(g, scene, track, x, y, size, radius) {
    g.clipped(() => g.roundRectPath(x, y, size, size, radius), () => {
        const cover = imageOf(scene, track.artworkId);
        if (cover) {
            g.drawImage(cover, x, y, size, size);
            hold(track.artworkId);
            return;
        }
        const waiting = heldFor(scene, track.artworkId);
        if (waiting) {
            g.drawImage(waiting, x, y, size, size);
            return;
        }
        g.fillRect(x, y, size, size, [1, 1, 1, 0.08]);
        // A cover on its way is not stood in for: the icon would blink before it.
        if (track.artworkId && !images.has(track.artworkId))
            return;
        const icon = imageOf(scene, track.iconId);
        if (icon) {
            const side = size * 0.6;
            g.drawImage(icon, x + (size - side) / 2, y + (size - side) / 2, side, side);
        }
    });
}

/** `TrackText`: the title in a 18-point frame, the artist in a 14, centred in `height`. */
function drawTrackText(g, track, x, top, width, height, {title = WHITE, artist = SECONDARY} = {}) {
    const titleH = g.lineHeight(MusicType.title), artistH = g.lineHeight(MusicType.artist);
    const block = 18 + (track.artist ? 14 : 0);
    const y0 = top + (height - block) / 2;
    g.drawText(track.title, x, y0 + (18 - titleH) / 2, MusicType.title, title, {maxWidth: width});
    if (track.artist)
        g.drawText(track.artist, x, y0 + 18 + (14 - artistH) / 2, MusicType.artist, artist, {maxWidth: width});
}

/**
 * A plain button's glyph, dimmed while it is held down (`.buttonStyle(.plain)`):
 * as one picture, since its parts may overlap.
 */
function drawPressable(g, scene, id, draw) {
    g.group(isPressed(scene, id) ? PRESSED_OPACITY : 1, draw);
}

/** An SF Symbol's line at `size` points: what a plain button's frame is tall. */
const symbolLine = (g, size) => g.lineHeight({size, weight: 600, family: 'system'});

/**
 * `MusicControls`: previous, play or pause, next, eight apart. Plain buttons:
 * each answers in its glyph's own frame, the symbol's width by its line, and
 * the pointer stays an arrow.
 */
function drawControls(g, scene, x, centerY, small, large, track, idBase) {
    let cx = x;
    const buttons = [
        ['prev', 'backward', small, symbolWidth.backward(small), {command: 'previous'}, t('Previous track')],
        ['toggle', track.isPlaying ? 'pause' : 'play', large, symbolWidth.play(large), {command: 'togglePlayPause'}, track.isPlaying ? t('Pause') : t('Play')],
        ['next', 'forward', small, symbolWidth.forward(small), {command: 'next'}, t('Next track')],
    ];
    for (const [id, kind, size, width, command, label] of buttons) {
        const hitId = `${idBase}:${id}`;
        drawPressable(g, scene, hitId, () => drawTransport(g, kind, cx + width / 2, centerY, size, WHITE));
        const line = symbolLine(g, size);
        scene.addHit({
            id: hitId, x: cx, y: centerY - line / 2, w: width, h: line,
            label, onClick: () => call(scene, 'command', command),
        });
        cx += width + 8;
    }
}

const spoken = track => [track.isPlaying ? t('Now playing') : t('Paused'), track.title, track.artist].filter(Boolean).join(', ');

/** The bars' animations run at 24 frames a second (`preferredFrameRateRange`). */
const BAR_FRAME = 1 / 24;

/**
 * Seven bars, or Kapa in headphones where they stood (ADR 0006). Kapa sleeps
 * where she cannot be seen (`awake`); the bars move while `playing` says so.
 * On the page, nothing is drawn over her room, so she may have a layer of her own (`layer`).
 */
function drawEffect(g, scene, ctx, key, track, slot, {awake, playing, parts, layer}) {
    if (ctx.showsKapa) {
        ctx.drawKapa(g, key, slot.x, slot.y, slot.size, musicMood(track.isPlaying), {awake, parts, layer});
    } else {
        const {bars} = uiOf(scene);
        const set = key.includes('page') ? bars.page : bars.row;
        const moving = set.step(scene.now, {playing, still: ctx.model.reduceMotion === true});
        if (moving)
            frameAt(scene, scene.now + BAR_FRAME);
        set.draw(g, slot.x, slot.y, scene.now);
    }
}

// MARK: - The row under the compact strip

/** How far ahead the surface is told her notes will be over the strip: a frame or two can pass before it draws. */
const ABOVE_AHEAD = 0.15;

function drawRow(g, scene, box, ctx) {
    const track = ctx.module?.shown;
    if (!track)
        return;
    const row = rowLayout(box.width, box.x, box.y, {kapa: ctx.showsKapa});
    // Heard as what plays, its controls in it (`CompactMusicRow.spoken`).
    scene.addLabel?.({id: 'music-row', x: box.x, y: box.y, w: box.width, h: MusicType.rowHeight, label: spoken(track)});
    drawArtwork(g, scene, track, row.artwork.x, row.artwork.y, row.artwork.size, 10);
    drawTrackText(g, track, row.text.x, row.text.top, row.text.width, row.text.height);
    drawControls(g, scene, row.controls.x, row.controls.centerY, row.controls.small, row.controls.large, track, 'music-row');
    // On the host's layer Kapa or the bars are drawn there, and only they, while
    // nothing else moves; Kapa's tap stays with the surface, which keeps the hits.
    // The layer keeps off the top bar: what of hers floats up over the strip, a
    // note on its way out, the surface draws itself, while it is there.
    if (!ctx.layer)
        drawRowEffect(g, scene, box, ctx);
    else if (ctx.showsKapa && kapaAbove(scene, row.effect, box))
        drawEffect(g, scene, ctx, 'music-row', track, row.effect, {awake: !ctx.expanded, parts: [kapaParts(box, ctx).above]});
    else if (ctx.showsKapa)
        scene.kapaHit('music-row', row.effect.x, row.effect.y, row.effect.size, {awake: !ctx.expanded});
}

/**
 * The row's Kapa or bars. The bars keep moving under the fade as the surface
 * opens (`EqualizerBars(isPlaying:)`); Kapa sleeps once it is open (`kapaAwake`).
 * Where she may go on the host's layer, Kapa is drawn in two parts, above the
 * row and the rest, each a picture of its own, on the surface as on the layer,
 * so the two are the same to the last bit when one hands her to the other. The
 * part above is drawn only while something of hers may be there.
 */
function drawRowEffect(g, scene, box, ctx) {
    const track = ctx.module?.shown;
    if (!track)
        return;
    const row = rowLayout(box.width, box.x, box.y, {kapa: ctx.showsKapa});
    let parts;
    if (ctx.showsKapa && scene.liveLayers) {
        const {above, below} = kapaParts(box, ctx);
        const over = kapaAbove(scene, row.effect, box);
        // On the layer, the part above is the surface's: it is asked for a frame to draw it.
        if (ctx.layer && over)
            scene.wantFrame();
        parts = over && !ctx.layer ? [above, below] : [below];
    }
    drawEffect(g, scene, ctx, 'music-row', track, row.effect, {awake: !ctx.expanded, playing: track.isPlaying, parts});
}

/**
 * Kapa's room in the row: her square, with the room round it she moves and
 * floats her signs in — half her size above, a quarter at the sides and below —
 * cut where the row begins. Her notes rise a third of her size over her square,
 * her hearts less, and her squash and boop keep within a thirtieth of it; what
 * is drawn beyond the room is lost (`Gfx.isolated`).
 */
function kapaParts(box, ctx) {
    const {effect} = rowLayout(box.width, box.x, box.y, {kapa: true});
    const side = effect.size / 4;
    const x = effect.x - side, y = effect.y - effect.size / 2, w = effect.size + 2 * side, bottom = effect.y + effect.size + side;
    return {above: {x, y, w, h: box.y - y}, below: {x, y: box.y, w, h: bottom - box.y}};
}

/** Whether anything of hers may be above the row from now until a little after (`KapaEngine.reach`). */
function kapaAbove(scene, effect, box) {
    const engine = scene.engines.get('music-row');
    return !!engine && effect.y - engine.reach(scene.now + ABOVE_AHEAD) * effect.size / 100 < box.y;
}

/** Where the row's layer draws: the bars at their pitch, as tall as their slot; Kapa's room below the strip. */
function rowEffectRect(box, ctx) {
    if (ctx.showsKapa)
        return kapaParts(box, ctx).below;
    const {effect} = rowLayout(box.width, box.x, box.y, {kapa: false});
    return {x: effect.x, y: effect.y, w: EQUALIZER.width, h: uiOf(ctx.scene).bars.row.height};
}

// MARK: - The expanded surface's page

const pageVisible = (scene, ctx) => ctx.expanded && (ctx.selectedPage === 'music' || scene.travel !== 0);

/** The timeline starts when the page can be seen, and again when the track starts playing. */
function followBeat(scene, track, visible) {
    const {beat} = uiOf(scene);
    const playing = !!track?.isPlaying;
    if (!visible) {
        beat.since = null;
        return;
    }
    if (beat.since == null || playing && !beat.playing) {
        beat.since = scene.now;
        beat.sinceMs = Date.now();
    }
    beat.playing = playing;
}

function drawPage(g, scene, box, ctx) {
    const state = ctx.module;
    if (!state)
        return;
    const visible = pageVisible(scene, ctx);
    followBeat(scene, state.loaded, visible);
    if (state.loaded)
        drawTrackPage(g, scene, box, ctx, state.loaded, visible);
    else
        drawIdlePage(g, scene, box, ctx, state.remembered);
}

function drawTrackPage(g, scene, box, ctx, track, visible) {
    const page = pageLayout(box.width, box.x, box.y, {kapa: ctx.showsKapa});
    scene.addLabel?.({id: 'music-page', x: box.x, y: box.y, w: box.width, h: Metrics.pageHeight, label: spoken(track)});
    drawArtwork(g, scene, track, page.artwork.x, page.artwork.y, page.artwork.size, 20);

    // The title and artist, and Kapa or the bars at the right of them.
    drawTrackText(g, track, page.text.x, page.text.top, page.text.width, page.text.height);
    drawEffect(g, scene, ctx, 'music-page', track, page.effect, {awake: visible, playing: track.isPlaying && visible, layer: true});

    drawProgress(g, scene, track, page.progress, visible);

    const controls = page.controls;
    drawControls(g, scene, controls.x, controls.top + controls.height / 2, controls.small, controls.large, track, 'music');
    drawVolume(g, scene, ctx, page.volume);
}

/**
 * The moment the bar is drawn for: the last beat of its one-second timeline
 * while the track plays and the page can be seen, or the last time something
 * redrew it between beats (a reading, a drag) — `max(now, Date())` in the Swift,
 * where the body is only evaluated then.
 */
function barClock(scene, track, visible, nowMs) {
    const {beat, progress} = uiOf(scene);
    const key = readingKey(track);
    if (key !== beat.key || progress.pending) {
        beat.key = key;
        beat.changedMs = nowMs;
    }
    if (!visible || !track.isPlaying || beat.since == null)
        return nowMs;
    const beats = Math.floor((nowMs - beat.sinceMs) / 1000);
    // The next beat, on the scene's clock: one frame then, not one every frame.
    frameAt(scene, beat.since + beats + 1);
    return Math.max(beat.sinceMs + beats * 1000, beat.changedMs);
}

/**
 * A `Capsule` `w` wide, as SwiftUI draws one: nothing at no width, its ends
 * never wider than it, and circular (`Capsule`'s default style).
 */
function fillCapsule(g, x, y, w, h, color) {
    if (w > 0)
        g.fillRoundRect(x, y, w, h, Math.min(w, h) / 2, color, {circular: true});
}

/** The bar: the whole width answers a drag, not only what has been played — seeking forward is the common case. */
function drawProgress(g, scene, track, bar, visible) {
    const {progress} = uiOf(scene);
    const now = Date.now();
    const view = progress.view(track, now, barClock(scene, track, visible, now));
    fillCapsule(g, bar.x, bar.y, bar.width, bar.height, Colors.track);
    fillCapsule(g, bar.x, bar.y, bar.width * view.fraction, bar.height, WHITE);
    const font = MusicType.time;
    g.drawText(view.positionText, bar.x, bar.timesY + (14 - g.lineHeight(font)) / 2, font, SECONDARY);
    g.drawText(view.durationText, bar.x + bar.width, bar.timesY + (14 - g.lineHeight(font)) / 2, font, SECONDARY, {align: 'right'});
    // A finger on the bar, or a seek waiting for its reading, follows at once.
    if (progress.pending)
        scene.wantFrame();

    const slop = 6;
    scene.addHit({
        id: 'music:progress', x: bar.x - slop, y: bar.y - slop, w: bar.width + 2 * slop, h: bar.height + 2 * slop,
        label: t('Position'),
        onDrag: (x, _y, phase) => {
            if (phase !== 'ended')
                progress.drag((x - bar.x) / bar.width, track);
            else {
                const to = progress.endDrag(track, Date.now());
                if (to != null)
                    call(scene, 'command', {command: 'seek', to});
            }
            scene.onChange();
        },
    });
}

/** `Speaker.icon` for a level being dragged: dragging up from silence unmutes. */
const iconFor = level => (level <= 0 ? 'slash' : level < 1 / 3 ? 'wave1' : 'wave2');

/** How long a let-go level waits for the audio system to say it back. */
const VOLUME_ECHO_MS = 1000;

/**
 * The output volume, at the right of the controls: nothing when the output's
 * level cannot be set. The Swift sets the level and reads it back before the
 * next frame; here the answer comes later, so the bar shows the finger's
 * level until the state says the same, or a second has passed.
 */
function drawVolume(g, scene, ctx, volume) {
    const speaker = ctx.module.volume;
    if (!speaker)
        return;
    const ui = uiOf(scene);
    if (ui.volumeDrag?.endedAt != null
        && (Math.abs(speaker.shownLevel - ui.volumeDrag.level) < 0.02 || Date.now() - ui.volumeDrag.endedAt > VOLUME_ECHO_MS))
        ui.volumeDrag = null;
    if (ui.volumeDrag?.endedAt != null)
        scene.wantFrame();
    const level = ui.volumeDrag ? ui.volumeDrag.level : speaker.shownLevel;
    const icon = ui.volumeDrag ? iconFor(level) : speaker.icon;
    const {button, barX, barY} = volume;
    drawPressable(g, scene, 'music:mute', () => drawSpeaker(g, icon, button.x + button.width / 2, button.y + button.height / 2, 13, SECONDARY));
    scene.addHit({
        id: 'music:mute', x: button.x, y: button.y, w: button.width, h: button.height,
        label: speaker.isMuted ? t('Unmute') : t('Mute'), onClick: () => call(scene, 'volume.toggleMute'),
    });
    fillCapsule(g, barX, barY, 88, 4, Colors.track);
    fillCapsule(g, barX, barY, 88 * level, 4, WHITE);
    scene.addHit({
        id: 'music:volume', x: barX - 8, y: barY - 8, w: 88 + 16, h: 4 + 16, label: t('Volume'),
        description: t('%d percent', Math.round(level * 100)),
        onDrag: (x, _y, phase) => {
            const ended = phase === 'ended';
            const to = Math.min(Math.max((x - barX) / 88, 0), 1);
            ui.volumeDrag = {level: to, endedAt: ended ? Date.now() : null};
            setLevel(scene, to, ended);
            scene.onChange();
        },
    });
}

/** At most a few a second while dragging — each is a call to the audio system — and always the last. */
function setLevel(scene, level, last) {
    const ui = uiOf(scene);
    const now = Date.now();
    const clamped = Math.min(Math.max(level, 0), 1);
    if (!last && now - ui.volumeSent.at < 80)
        return;
    if (ui.volumeSent.level === clamped && !last)
        return;
    ui.volumeSent = {at: now, level: clamped};
    call(scene, 'volume.setLevel', {level: clamped});
}

/** The page while nothing is loaded: the last track dimmed, with where and when it played, or a note. */
function drawIdlePage(g, scene, box, ctx, remembered) {
    const idle = idleLayout(box.width, box.x, box.y, {remembered});
    const art = idle.artwork;
    if (remembered) {
        g.withAlpha(0.35, () => drawArtwork(g, scene, remembered.track, art.x, art.y, art.size, 20));
    } else {
        g.fillRoundRect(art.x, art.y, art.size, art.size, 20, [1, 1, 1, 0.06]);
        drawNote(g, art.x + art.size / 2, art.y + art.size / 2, 40, [1, 1, 1, 0.22]);
    }

    const col = idle.column;
    const titleH = g.lineHeight(MusicType.title), artistH = g.lineHeight(MusicType.artist);
    const nothingFont = Type.geist(13, 500);
    const nothingH = g.lineHeight(nothingFont);
    const captionH = artistH;
    const words = nothingH + 3 + captionH;
    let top;
    if (remembered) {
        const track = remembered.track;
        const trackH = track.artist ? titleH + artistH : titleH;
        const kapaSize = 38;
        const first = Math.max(trackH, ctx.showsKapa ? kapaSize : 0);
        const total = first + 20 + words;
        top = col.top + (col.height - total) / 2;
        const textWidth = col.width - (ctx.showsKapa ? kapaSize + 12 : 0);
        const y = top + (first - trackH) / 2;
        g.drawText(track.title, col.x, y, MusicType.title, [1, 1, 1, 0.6], {maxWidth: textWidth});
        if (track.artist)
            g.drawText(track.artist, col.x, y + titleH, MusicType.artist, [1, 1, 1, 0.38], {maxWidth: textWidth});
        if (ctx.showsKapa)
            // Headphones still on, waiting: the last track is loaded in no player, so Kapa holds still.
            ctx.drawKapa(g, 'music-idle', col.x + col.width - kapaSize, top + (first - kapaSize) / 2, kapaSize, 'paused', {awake: false});
        top += first + 20;
    } else {
        top = col.top + (col.height - words) / 2;
    }
    g.drawText(t('Nothing playing'), col.x, top, nothingFont, [1, 1, 1, 0.8]);
    g.drawText(idleCaption(remembered), col.x, top + nothingH + 3, MusicType.artist, [1, 1, 1, 0.45], {maxWidth: col.width});
    // The page is heard as one: what it says, in the order it says it (`.accessibilityElement(children: .combine)`).
    const said = [remembered?.track.title, remembered?.track.artist, t('Nothing playing'), idleCaption(remembered)];
    scene.addLabel?.({id: 'music-idle', x: box.x, y: box.y, w: box.width, h: Metrics.pageHeight, label: said.filter(Boolean).join(', ')});
}

function idleCaption(remembered) {
    if (!remembered)
        return t('Play a track in any player and it shows up here');
    const time = clock(Date.parse(remembered.endedAt) / 1000);
    // The application's name as a person knows it (the desktop file's, else the
    // player's own); a bare id is no name, and then only the time is said.
    const player = remembered.track.playerName;
    return player ? t('Played in %@ · %@', player, time) : t('Played at %@', time);
}

// MARK: - The Module

/**
 * The audio system is listened to while the surface is open on a Module with a
 * track loaded — the page that holds the bar is built then, whichever page is
 * shown, so a swipe towards it finds the level already read — and never
 * otherwise (ADR 0003). The level itself is read once as a track loads, by the
 * Module, so the first open has it already.
 */
function reconcileWatching(ctx) {
    const on = !!(ctx.expanded && ctx.module?.on && ctx.module?.loaded);
    const ui = uiOf(ctx.scene);
    if (on === ui.watching)
        return;
    ui.watching = on;
    call(ctx.scene, 'volume.watch', {on});
}

export default {
    id: MODULE,
    page: 'music',
    drawPage,

    /**
     * Playing, or paused for less than ten seconds; not over a fullscreen
     * application. The bars are the row's moving part, which a host may draw on
     * a layer of its own (`layer`), and so is Kapa where they stand.
     */
    compactRow(ctx) {
        if (ctx.fullscreen || !ctx.module?.shown)
            return null;
        return {priority: 10, height: MusicType.rowHeight, draw: drawRow, layer: {rect: rowEffectRect, draw: drawRowEffect}};
    },

    /**
     * Every frame for a finger on a bar or a seek waiting for its reading;
     * otherwise frames on a beat (`{interval}`, seconds): 1/24 while the bars
     * move (Kapa asks for hers), and the page's next one-second beat while the
     * track plays and the page can be seen. Over a fullscreen application the
     * row is not there, and asks for nothing; with the bars on the host's layer
     * (`rowLayer`), the layer asks for its own frames.
     */
    needsFrames(ctx) {
        reconcileWatching(ctx);
        const state = ctx.module;
        prune(state);
        const ui = uiOf(ctx.scene);
        if (!ctx.expanded || !pageVisible(ctx.scene, ctx))
            ui.beat.since = null;
        // A let-go level whose answer never came is given up here too, drawn or not.
        if (ui.volumeDrag?.endedAt != null && Date.now() - ui.volumeDrag.endedAt > VOLUME_ECHO_MS)
            ui.volumeDrag = null;
        if (!state?.on)
            return false;
        let interval = Infinity;
        if (ctx.expanded) {
            if (ui.progress.pending || ui.volumeDrag != null)
                return true;
            const playing = !!state.loaded?.isPlaying && pageVisible(ctx.scene, ctx);
            if (playing && !ctx.showsKapa)
                interval = BAR_FRAME;
            if (playing && ui.beat.since != null) {
                const into = ((Date.now() - ui.beat.sinceMs) / 1000) % 1;
                interval = Math.min(interval, Math.max(1 - into, 0.001));
            }
        } else if (!ctx.fullscreen && !!state.shown?.isPlaying && !ctx.showsKapa && !ctx.rowLayer) {
            interval = BAR_FRAME;
        }
        return Number.isFinite(interval) ? {interval} : false;
    },
};

export {controlsWidth, spoken};
