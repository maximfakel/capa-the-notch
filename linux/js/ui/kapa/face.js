// Kapa's poses and the face each draws — a port of `KapaFace.of` in
// `linux/crates/core/src/kapa/face.rs`. A pose is a face; the renderer draws parts,
// so a new pose is a new row here, not a new drawing. The Rust side is the
// reference: `test/fixtures/kapa.json` is written from it and both sides
// check themselves against it.

export const EXPRESSIONS = [
    'rest', 'focused', 'curious', 'music', 'paused', 'dropReady', 'received', 'listening', 'thinking',
    'inserted', 'copied', 'worried', 'waiting', 'stale', 'puzzled', 'failed', 'hello', 'quiet',
];

/** A turn of the head: yaw to the right, pitch upwards, in radians. */
export const LOOK = {
    ahead: {yaw: 0, pitch: 0},
    /** Up and to the left: where the Dictation Capsule's orb is from the corner Kapa sits in. */
    towardTheOrb: {yaw: -0.2, pitch: 0.15},
};

const face = (eyes, mouth, extra = {}) => ({
    eyes, mouth, brows: 'none', badge: 'none', headphones: false, blush: false,
    look: LOOK.ahead, tilt: 0, reaction: 'none', ...extra,
});

export function faceOf(expression) {
    switch (expression) {
    case 'rest': return face('open', 'smile');
    case 'focused': return face('open', 'line');
    case 'curious': return face('open', 'small', {look: {yaw: 0.12, pitch: 0.12}});
    case 'music': return face('happy', 'grin', {badge: 'note', headphones: true, reaction: 'nod'});
    case 'paused': return face('open', 'line', {headphones: true});
    case 'dropReady': return face('wide', 'open', {badge: 'file', look: {yaw: -0.08, pitch: 0.14}});
    case 'received': return face('happy', 'small', {badge: 'check', blush: true, reaction: 'gulp'});
    case 'listening': return face('open', 'small', {look: LOOK.towardTheOrb});
    case 'thinking': return face('narrowed', 'line', {look: LOOK.towardTheOrb});
    case 'inserted': return face('happy', 'grin', {badge: 'check', reaction: 'nod'});
    case 'copied': return face('open', 'small', {badge: 'clipboard', look: LOOK.towardTheOrb});
    case 'worried': return face('open', 'worried', {brows: 'worried', badge: 'alert'});
    case 'waiting': return face('closed', 'line', {badge: 'clock'});
    case 'stale': return face('lidded', 'line', {badge: 'dashedClock'});
    case 'puzzled': return face('uneven', 'wobble', {brows: 'puzzled', badge: 'unplugged', tilt: -4});
    case 'failed': return face('uneven', 'wobble', {brows: 'puzzled', badge: 'cross', tilt: -4});
    case 'hello': return face('happy', 'grin', {badge: 'sparkle', reaction: 'hop'});
    case 'quiet': return face('open', 'line', {badge: 'pause'});
    default: throw new Error(`no such Kapa pose: ${expression}`);
    }
}

/** Faces compare by what they draw, as Swift's `Equatable` struct does. */
export function faceEquals(a, b) {
    return a.eyes === b.eyes && a.mouth === b.mouth && a.brows === b.brows && a.badge === b.badge
        && a.headphones === b.headphones && a.blush === b.blush && a.look.yaw === b.look.yaw
        && a.look.pitch === b.look.pitch && a.tilt === b.tilt && a.reaction === b.reaction;
}

export const KAPA_PREFERENCE = {key: 'showsKapa', defaultValue: true};
