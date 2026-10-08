// What only a program with a window can do for the Shelf on GNOME: be where a
// file is dropped. The Shell is told where a drag is but not what it carries, and
// has no drop target of its own for it, so while a drag is going on the extension
// stands this transparent window under the surface (dnd-host.js) and it takes the
// drop as any program would. (A window that draws nothing at all is never given a
// buffer, and the Shell never shows it: so it draws one pixel, a hundredth of black.)
//
// It talks back through its title, which the extension watches:
//   capa-drop:idle      nothing over it
//   capa-drop:files     something it can take is carried over it
//   capa-drop:dropping  it was let go with something the Shelf takes; it is being added
//   capa-drop:added     they are in the Shelf
//   capa-drop:nothing   it was let go, and there was nothing in it the Shelf takes
// and is asked, over its D-Bus actions, to `show` and `hide` (the window exists
// only for the length of a drag; the program stays, so that it is there in time).

import Gdk from 'gi://Gdk?version=4.0';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Gtk from 'gi://Gtk?version=4.0';

const TITLE = 'capa-drop:';

const DAEMON = {name: 'tech.capathenotch.Daemon', path: '/tech/capathenotch/Daemon', iface: 'tech.capathenotch.Daemon1'};

function shelf(method, args) {
    return new Promise((resolve, reject) => {
        Gio.DBus.session.call(DAEMON.name, DAEMON.path, DAEMON.iface, 'Call',
            new GLib.Variant('(sss)', ['shelf', method, JSON.stringify(args)]), null,
            Gio.DBusCallFlags.NONE, -1, null, (bus, result) => {
                try {
                    resolve(bus.call_finish(result));
                } catch (e) {
                    reject(e);
                }
            });
    });
}

const app = new Gtk.Application({application_id: 'tech.capathenotch.DropCatcher'});
let window = null;

function say(state) {
    if (window)
        window.title = `${TITLE}${state}`;
}

function build() {
    const provider = new Gtk.CssProvider();
    provider.load_from_string('window.capa-drop { background: transparent; } .capa-dot { background: rgba(0, 0, 0, 0.01); }');
    Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);

    window = new Gtk.Window({application: app, decorated: false, default_width: 200, default_height: 80,
        title: `${TITLE}idle`});
    window.add_css_class('capa-drop');
    window.set_focusable(false);

    // Asynchronous, so that what was dropped can be asked for in turn: a browser
    // offers an image both as a list of files (often none on this disk) and as the
    // picture itself, and a synchronous target takes only the first it matches.
    const builder = Gdk.ContentFormatsBuilder.new();
    builder.add_gtype(Gdk.FileList.$gtype);
    builder.add_gtype(Gdk.Texture.$gtype);
    const formats = builder.to_formats().union_deserialize_mime_types();
    const target = new Gtk.DropTargetAsync({actions: Gdk.DragAction.COPY, formats});
    target.connect('accept', (_t, drop) => offers(drop, Gdk.FileList.$gtype) || offers(drop, Gdk.Texture.$gtype));
    target.connect('drag-enter', () => {
        say('files');
        return Gdk.DragAction.COPY;
    });
    target.connect('drag-motion', () => Gdk.DragAction.COPY);
    target.connect('drag-leave', () => say('idle'));
    target.connect('drop', (_t, drop) => {
        // What was dropped is read first, as the app does: only a drop that has
        // something the Shelf takes is said to be dropping (Kapa eats it, it sounds).
        found(drop).then(what => {
            if (!what)
                return false;
            say('dropping');
            return add(what).then(() => true);
        }).then(added => {
            drop.finish(added ? Gdk.DragAction.COPY : 0);
            say(added ? 'added' : 'nothing');
        }, e => {
            console.error(`capa-the-notch drop: ${e}`);
            drop.finish(0);
            say('nothing');
        });
        return true;
    });
    window.add_controller(target);
    // One pixel that is not clear, so that there is something to draw (see the top of this file).
    const dot = new Gtk.Box({halign: Gtk.Align.START, valign: Gtk.Align.START, width_request: 1, height_request: 1});
    dot.add_css_class('capa-dot');
    window.set_child(dot);
    window.present();
}

/** Whether the drop can be had as `gtype`, by itself or through a deserializer. */
function offers(drop, gtype) {
    return drop.get_formats().union_deserialize_gtypes().contain_gtype(gtype);
}

/** One of the drop's values, or null when it has none of that kind. */
function read(drop, gtype) {
    if (!offers(drop, gtype))
        return Promise.resolve(null);
    return new Promise(resolve => {
        drop.read_value_async(gtype, GLib.PRIORITY_DEFAULT, null, (_d, result) => {
            try {
                resolve(drop.read_value_finish(result));
            } catch (_e) {
                resolve(null);
            }
        });
    });
}

/**
 * What in the drop the Shelf takes: files by their paths; failing any on this
 * disk, the picture itself. Null when there is neither.
 */
async function found(drop) {
    const files = await read(drop, Gdk.FileList.$gtype);
    const paths = (files?.get_files?.() ?? []).map(f => f.get_path()).filter(Boolean);
    if (paths.length)
        return {paths};
    const texture = await read(drop, Gdk.Texture.$gtype);
    if (texture instanceof Gdk.Texture)
        return {png: texture.save_to_png_bytes().get_data()};
    return null;
}

/** The Shelf takes it: the files, or the picture held in memory. */
function add(what) {
    if (what.paths)
        return shelf('add', {paths: what.paths});
    return shelf('addImage', {data: GLib.base64_encode(what.png)});
}

app.connect('startup', () => {
    app.hold();
    const show = new Gio.SimpleAction({name: 'show'});
    show.connect('activate', () => {
        if (!window)
            build();
        else
            window.present();
    });
    const hide = new Gio.SimpleAction({name: 'hide'});
    hide.connect('activate', () => {
        window?.destroy();
        window = null;
    });
    const quit = new Gio.SimpleAction({name: 'quit'});
    quit.connect('activate', () => app.quit());
    for (const action of [show, hide, quit])
        app.add_action(action);
});
app.connect('activate', () => {});
app.run([imports.system.programInvocationName]);
