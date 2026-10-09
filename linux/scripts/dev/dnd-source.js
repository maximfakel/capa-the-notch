import Gtk from 'gi://Gtk?version=4.0';
import Gdk from 'gi://Gdk?version=4.0';
import Gio from 'gi://Gio';
import GObject from 'gi://GObject';
const app = new Gtk.Application({application_id: 'test.dndsource'});
app.connect('activate', () => {
    const w = new Gtk.ApplicationWindow({application: app, title: 'dnd-source', default_width: 300, default_height: 200});
    const label = new Gtk.Label({label: 'DRAG ME', vexpand: true});
    const src = new Gtk.DragSource({actions: Gdk.DragAction.COPY});
    src.connect('prepare', () => {
        const list = Gdk.FileList.new_from_array([Gio.File.new_for_path('/tmp/capa-dragme.txt')]);
        return Gdk.ContentProvider.new_for_value(list);
    });
    label.add_controller(src);
    w.set_child(label);
    w.present();
});
app.run([]);
