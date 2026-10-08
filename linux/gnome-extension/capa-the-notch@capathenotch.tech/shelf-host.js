// What only the Shell can do for the Shelf Module.
//
//  - Watch the clipboard. GNOME on Wayland gives no background program the
//    clipboard (mutter has no data-control protocol), but the Shell is the
//    compositor: it sees every copy as it happens (`Meta.Selection`'s
//    `owner-changed`). It pushes what the hub asked for — never more — and
//    the hub's rules (`capa_core::shelf`) decide what is kept.
//  - Put a Clipping, or a file, on the clipboard.
//
// Dragging a file out of the surface to another program is not possible from
// the Shell (its drag and drop is for its own actors), so a tile that is
// dragged is put on the clipboard as a file and the person pastes it where it
// is wanted. Files carried in from other programs are dropped on the surface
// through a window of our own stood under it for the drag (dnd-host.js,
// drop-catcher.js); they also come in through the file manager's "Add to the
// CapaTheNotch Shelf" script (`linux/scripts/install-linux.sh`), or by copying.

import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import St from 'gi://St';

import {t} from './ui/strings.js';

const MAX_IMAGE_BYTES = 24 * 1024 * 1024;
/** The longest text the Shelf keeps (`Clippings.maximumLength`). */
const MAX_TEXT_CHARS = 100_000;
/** What `_bytes` answers for an image past that: not a refusal, only not sent. */
const TOO_LARGE = Symbol('too large');
/** Longer than a copy takes to settle, shorter than a person copies twice. */
const SETTLE_MS = 60;

const TEXT_TYPES = ['text/plain;charset=utf-8', 'text/plain', 'UTF8_STRING', 'STRING'];
/** `ClipboardTake::IMAGE_TYPES`, in its order: the image as it was first, TIFF — a converted copy — last. */
const IMAGE_TYPES = ['image/png', 'image/jpeg', 'image/webp', 'image/heic', 'image/heif', 'image/gif', 'image/tiff'];
const FILE_TYPES = ['x-special/gnome-copied-files', 'text/uri-list'];

/** Until when a change of the clipboard is CapaTheNotch's own write, which the Shelf does not keep. */
let ownUntil = 0;

/**
 * Puts text on the clipboard as CapaTheNotch's own (the Swift `OwnClipboard.copy`):
 * the Shelf does not take it back as a Clipping. For Dictation's text, too.
 */
export function writeOwnText(text) {
    ownUntil = GLib.get_monotonic_time() + 500_000;
    St.Clipboard.get_default().set_text(St.ClipboardType.CLIPBOARD, text);
}

export class ShelfHost {
    /**
     * @param {object} options
     * @param {() => object|null} options.shelfState the hub's `state.modules.shelf`
     * @param {(args: object) => Promise<any>} options.push sends what was read to the hub
     * @param {(title: string, body: string) => void} options.notify
     */
    constructor({shelfState, push, notify}) {
        this._shelfState = shelfState;
        this._push = push;
        this._notify = notify;
        this._count = 0;
        this._settle = 0;
        this._selection = global.display.get_selection();
        this._owner = this._selection.connect('owner-changed', (_s, type) => {
            if (type === Meta.SelectionType.SELECTION_CLIPBOARD)
                this._changed();
        });
    }

    destroy() {
        if (this._owner)
            this._selection.disconnect(this._owner);
        this._owner = 0;
        if (this._settle)
            GLib.source_remove(this._settle);
        this._settle = 0;
    }

    // MARK: - Writing

    /** Puts text on the clipboard, and does not take it back as a copy of someone else's. */
    writeText(text) {
        writeOwnText(text);
    }

    /** Puts a file on the clipboard as a file, so it pastes into a file manager, a mail, a chat. */
    writeFile(path) {
        ownUntil = GLib.get_monotonic_time() + 500_000;
        const uri = GLib.filename_to_uri(path, null);
        St.Clipboard.get_default().set_content(St.ClipboardType.CLIPBOARD, 'x-special/gnome-copied-files',
            new GLib.Bytes(new TextEncoder().encode(`copy\n${uri}`)));
        this._notify(t('File copied'), t('Paste it where you want it.'));
    }

    // MARK: - Reading

    /** A copy happened. Nothing is read unless the Shelf asked for it. */
    _changed() {
        if (GLib.get_monotonic_time() < ownUntil)
            return;
        const shelf = this._shelfState();
        if (!shelf?.pushClipboard || !shelf.wantsClipboard)
            return;
        // Give the copying program a moment to finish offering its types.
        if (this._settle)
            GLib.source_remove(this._settle);
        this._settle = GLib.timeout_add(GLib.PRIORITY_DEFAULT, SETTLE_MS, () => {
            this._settle = 0;
            this._read(shelf).catch(e => console.error(`capa-the-notch: clipboard: ${e}`));
            return GLib.SOURCE_REMOVE;
        });
    }

    async _read(shelf) {
        const clipboard = St.Clipboard.get_default();
        const types = clipboard.get_mimetypes(St.ClipboardType.CLIPBOARD) ?? [];
        const frontmost = this._frontmost();
        // A password app that marks nothing: nothing is read while it is in front.
        if (frontmost && (shelf.excludedApplications ?? []).includes(frontmost))
            return;
        // Copying in a file manager is left alone, so its files are not even read.
        const fromFileManager = !!frontmost && (shelf.fileManagers ?? []).includes(frontmost);
        const push = {
            count: ++this._count,
            frontmost,
            types: [types],
            text: null,
            filePath: null,
            data: {},
            tooLarge: [],
        };
        // A copy that says it is secret is never read: only its types go, so the hub sees the marker.
        const secret = types.some(type => (shelf.secretMarkers ?? []).includes(type));
        if (!secret) {
            // An application the person excluded keeps its text out; its images and files still come.
            const textBlocked = !!frontmost && (shelf.textExcludedApplications ?? []).includes(frontmost);
            if (shelf.wantsText && !textBlocked && types.some(type => TEXT_TYPES.includes(type))) {
                const text = await this._text(clipboard);
                // Past the Shelf's limit it is not kept (`Clippings.maximumLength`), so it is not
                // carried over the bus either: a copied page can be megabytes.
                push.text = text && [...text].length <= MAX_TEXT_CHARS ? text : null;
            }
            if (shelf.wantsImages) {
                // The first the hub would take; one too large for the bus is said so, and the next tried.
                for (const image of IMAGE_TYPES.filter(type => types.includes(type))) {
                    const bytes = await this._bytes(clipboard, image, true);
                    if (bytes === TOO_LARGE) {
                        push.tooLarge.push(image);
                        continue;
                    }
                    if (bytes != null)
                        push.data[image] = bytes;
                    break;
                }
                const files = FILE_TYPES.find(type => types.includes(type));
                if (files && !fromFileManager)
                    push.filePath = this._firstFile(await this._bytes(clipboard, files, false));
            }
        }
        for (const key of Object.keys(push.data)) {
            if (push.data[key] == null)
                delete push.data[key];
        }
        await this._push(push);
    }

    _text(clipboard) {
        return new Promise(resolve => clipboard.get_text(St.ClipboardType.CLIPBOARD, (_c, text) => resolve(text ?? null)));
    }

    /** The bytes of one type; images come back as base64 for the bus, and past a limit as `TOO_LARGE`. */
    _bytes(clipboard, mimetype, asBase64) {
        return new Promise(resolve => clipboard.get_content(St.ClipboardType.CLIPBOARD, mimetype, (_c, bytes) => {
            if (!bytes) {
                resolve(null);
                return;
            }
            if (bytes.get_size() > MAX_IMAGE_BYTES) {
                resolve(TOO_LARGE);
                return;
            }
            resolve(asBase64 ? GLib.base64_encode(bytes.get_data()) : new TextDecoder().decode(bytes.get_data()));
        }));
    }

    /** `file:///a/b%20c` lines, `copy` or `cut` first in GNOME's own format. */
    _firstFile(text) {
        const uri = (text ?? '').split(/\r?\n/).find(line => line.startsWith('file://'));
        try {
            return uri ? GLib.filename_from_uri(uri)[0] : null;
        } catch (_e) {
            return null;
        }
    }

    /**
     * The program in front when it was copied: its desktop-file id without `.desktop`
     * ("org.gnome.Nautilus"), as the rules' lists name programs; else the window's own.
     */
    _frontmost() {
        const window = global.display.focus_window;
        if (!window)
            return null;
        const app = Shell.WindowTracker.get_default().get_window_app(window);
        const id = app?.get_id?.();
        if (id && !id.startsWith('window:'))
            return id.replace(/\.desktop$/, '');
        return window.get_gtk_application_id?.() || window.get_wm_class?.() || null;
    }
}
