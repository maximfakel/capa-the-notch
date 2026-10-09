// Where the track is and where the bar was dragged to: `MusicProgress` in
// MusicViews.swift, and `capa_core::music::MusicProgress` in Rust, which this
// follows rule for rule. Times are wall-clock milliseconds, because a track's
// position is reported as an instant on the machine's clock.

export const SETTLE_WITHIN = 2; // seconds
export const GIVE_UP_AFTER = 3000; // milliseconds

export const clockText = seconds => {
    const whole = Math.floor(Math.max(seconds, 0));
    return `${String(Math.floor(whole / 60)).padStart(2, '0')}:${String(whole % 60).padStart(2, '0')}`;
};

/** Where a track is at `nowMs`: its reported position moved on at its rate, never outside it. */
export function trackPosition(track, nowMs) {
    if (track.elapsed == null)
        return null;
    const at = track.elapsedAt ? Date.parse(track.elapsedAt) : nowMs;
    const moved = track.elapsedAt ? ((nowMs - at) / 1000) * (track.rate ?? 0) : 0;
    const position = Math.max(track.elapsed + moved, 0);
    return track.duration != null ? Math.min(position, track.duration) : position;
}

/**
 * What of a track makes a new reading when it changes (`.onChange(of: track)`):
 * what may settle a seek, and what redraws the bar between beats.
 */
export const readingKey = track => [track.title, track.elapsed, track.elapsedAt, track.isPlaying, track.rate, track.duration].join('\u0000');

export class Progress {
    constructor() {
        this.dragged = null;
        this.sought = null;
    }

    expected(track, nowMs) {
        const rate = track.isPlaying ? (track.rate ?? 1) : 0;
        return this.sought.target + ((nowMs - this.sought.at) / 1000) * rate;
    }

    /**
     * One frame of the bar. `nowMs` is the machine's clock, which settles and
     * gives up a seek; `clockMs` is the moment the bar shows — the last beat of
     * its one-second timeline — and defaults to now.
     *
     * Nothing here belongs to a track: like the Swift's `@State`, what is
     * dragged or sought outlives a change of track, and is ended only by a
     * reading or by giving up.
     */
    view(track, nowMs, clockMs = nowMs) {
        const duration = track.duration ?? 0;
        // A seek unanswered for three seconds gives the bar back (`.task(id: sought)`).
        if (this.sought && nowMs - this.sought.at >= GIVE_UP_AFTER)
            this.sought = null;
        // A new reading that lands near the target settles it (`.onChange(of: track)`).
        if (this.sought && readingKey(track) !== this.sought.reading) {
            this.sought.reading = readingKey(track);
            const reported = trackPosition(track, nowMs);
            if (reported != null && Math.abs(reported - this.expected(track, nowMs)) < SETTLE_WITHIN)
                this.sought = null;
        }
        const position = this.dragged != null
            ? this.dragged * duration
            : this.sought
                ? Math.min(this.expected(track, clockMs), duration)
                : trackPosition(track, clockMs) ?? 0;
        const fraction = duration > 0 ? Math.min(Math.max(position / duration, 0), 1) : 0;
        return {position, fraction, duration, positionText: clockText(position), durationText: clockText(duration)};
    }

    /** A pointer on the bar, as a fraction of its width. A track with no duration cannot be sought. */
    drag(fraction, track) {
        if ((track.duration ?? 0) > 0)
            this.dragged = Math.min(Math.max(fraction, 0), 1);
    }

    /** Let go: the seek to send, in seconds, if any. */
    endDrag(track, nowMs) {
        const dragged = this.dragged;
        this.dragged = null;
        const duration = track.duration ?? 0;
        if (dragged == null || duration <= 0)
            return null;
        // The reading the seek was made against: only a later one can settle it.
        this.sought = {target: dragged * duration, at: nowMs, reading: readingKey(track)};
        return dragged * duration;
    }

    get pending() {
        return this.sought != null || this.dragged != null;
    }
}
