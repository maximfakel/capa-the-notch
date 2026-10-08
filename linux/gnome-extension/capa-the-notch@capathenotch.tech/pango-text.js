// Text for the shared scene on Cairo, through Pango: the GNOME extension's
// text backend.
//
// This runs inside the compositor, sixty times a second, for every word on
// the surface — so it allocates nothing it can reuse. A layout made afresh
// for each word, as this once did, leaked tens of kilobytes a frame and took
// the Shell past 11 GB: font descriptions and one layout are kept for good,
// and a width is measured once for each (text, font) it is asked about.

import Gio from 'gi://Gio';
import Pango from 'gi://Pango';
import PangoCairo from 'gi://PangoCairo';

import {lineMetrics, setSystemFontMetrics} from './ui/gfx.js';

/** The system font where the desktop does not name one: GNOME's own, then its old one. */
const SYSTEM_FALLBACK = 'Adwaita Sans, Cantarell, Inter, sans-serif';
/** Measured widths kept at most; a surface says a few hundred distinct things. */
const MEASURE_LIMIT = 2000;
/** The size the system font's metrics are read at: large, so hinting rounds them by nothing that shows. */
const METRICS_SIZE = 4096;

export class PangoText {
    /** @param {{onChange?: () => void}} options told when the desktop's font changes, to draw again */
    constructor({onChange = null} = {}) {
        const context = PangoCairo.font_map_get_default().create_context();
        // SwiftUI places glyphs at fractional advances: rounded, a measured
        // width and the width drawn would not agree.
        context.set_round_glyph_positions(false);
        this._layout = Pango.Layout.new(context);
        this._fonts = new Map();
        this._widths = new Map();
        this._families = {geist: 'Geist, Cantarell, sans-serif', system: SYSTEM_FALLBACK};
        this._onChange = onChange;
        // The status chip and the glyphs are in the system's font (`Font.system`):
        // here the desktop's interface font, read once and followed as it changes.
        this._interface = null;
        try {
            this._interface = new Gio.Settings({schema_id: 'org.gnome.desktop.interface'});
            this._fontChanged = this._interface.connect('changed::font-name', () => {
                this._followSystemFont();
                this._onChange?.();
            });
        } catch (_e) {
            // No such schema: GNOME's own font.
        }
        this._followSystemFont();
    }

    /**
     * The family the desktop names (`font-name`, as "Adwaita Sans 11"), ahead of
     * the fallbacks; and where that font stands on its line, read from the font
     * Pango resolves, so the rows centre what is drawn and not a stand-in.
     */
    _followSystemFont() {
        let family = null;
        try {
            family = Pango.FontDescription.from_string(this._interface?.get_string('font-name') ?? '').get_family();
        } catch (_e) {
            family = null;
        }
        this._families.system = family ? `${family}, ${SYSTEM_FALLBACK}` : SYSTEM_FALLBACK;
        this._fonts.clear();
        this._widths.clear();
        const desc = new Pango.FontDescription();
        desc.set_family(this._families.system);
        desc.set_weight(600);
        desc.set_absolute_size(METRICS_SIZE * Pango.SCALE);
        const metrics = this._layout.get_context().load_font(desc)?.get_metrics(null);
        if (!metrics)
            return;
        const ascent = metrics.get_ascent() / Pango.SCALE / METRICS_SIZE;
        const descent = metrics.get_descent() / Pango.SCALE / METRICS_SIZE;
        const height = metrics.get_height() / Pango.SCALE / METRICS_SIZE;
        if (ascent > 0)
            setSystemFontMetrics({ascent, lineHeight: height > 0 ? height : ascent + descent});
    }

    destroy() {
        if (this._fontChanged)
            this._interface.disconnect(this._fontChanged);
        this._fontChanged = 0;
        this._interface = null;
        this._onChange = null;
    }

    _description(font) {
        const key = `${font.family ?? 'geist'}/${font.weight ?? 400}/${font.size}/${font.kern ?? 0}/${font.tabular ? 'tnum' : ''}`;
        let entry = this._fonts.get(key);
        if (!entry) {
            const desc = new Pango.FontDescription();
            desc.set_family(this._families[font.family ?? 'geist']);
            desc.set_weight(font.weight ?? 400);
            desc.set_absolute_size(font.size * Pango.SCALE);
            // Tracking, as `.kerning()` is in SwiftUI: points added after each glyph.
            let attributes = null;
            if (font.kern || font.tabular) {
                attributes = new Pango.AttrList();
                if (font.kern)
                    attributes.insert(Pango.attr_letter_spacing_new(Math.round(font.kern * Pango.SCALE)));
                // Figures all one width, as `.monospacedDigit()` sets them.
                if (font.tabular)
                    attributes.insert(Pango.attr_font_features_new('tnum'));
            }
            entry = {desc, attributes};
            this._fonts.set(key, entry);
        }
        return {key, desc: entry.desc, attributes: entry.attributes};
    }

    /** Points the one layout at `str` in `font`, with no width limit. */
    _set(str, font) {
        const {key, desc, attributes} = this._description(font);
        const layout = this._layout;
        layout.set_attributes(attributes);
        layout.set_width(-1);
        layout.set_ellipsize(Pango.EllipsizeMode.NONE);
        layout.set_font_description(desc);
        layout.set_text(str, -1);
        return key;
    }

    /** The layout's logical width, unrounded: what SwiftUI would lay out. */
    _width() {
        return this._layout.get_extents()[1].width / Pango.SCALE;
    }

    measure(str, font) {
        const {key} = this._description(font);
        const id = `${key}|${str}`;
        let width = this._widths.get(id);
        if (width === undefined) {
            this._set(str, font);
            width = this._width();
            if (this._widths.size >= MEASURE_LIMIT)
                this._widths.clear();
            this._widths.set(id, width);
        }
        return width;
    }

    draw(wrapped, str, x, y, font, rgba, align, maxWidth) {
        // The scene draws through `CairoGjs`; Pango wants the context itself.
        const cr = wrapped.cr ?? wrapped;
        const layout = this._layout;
        this._set(str, font);
        if (maxWidth != null) {
            layout.set_width(Math.max(0, Math.round(maxWidth * Pango.SCALE)));
            layout.set_ellipsize(Pango.EllipsizeMode.END);
            layout.set_wrap(Pango.WrapMode.CHAR);
        }
        PangoCairo.update_layout(cr, layout);
        const width = this._width();
        const left = align === 'center' ? x - width / 2 : align === 'right' ? x - width : x;
        // On a surface, Pango's metrics are hinted: its baseline is rounded down
        // the line (16 for Geist's 15.075 at 15 points). The line's top is where
        // `y` says, and the baseline is the font's own ascent under it.
        const shift = lineMetrics(font).ascent - layout.get_baseline() / Pango.SCALE;
        cr.setSourceRGBA(rgba[0], rgba[1], rgba[2], rgba[3]);
        cr.moveTo(left, y + shift);
        PangoCairo.show_layout(cr, layout);
        return width;
    }
}
