// A media player for the test shell only: an MPRIS name on the bus it is started on,
// playing, with a cover it draws itself. Run inside the test shell (shell-test.py spawns it):
//
//   gjs -m fake-player.js [--switch SECONDS] [--dir DIR]
//
// --switch: the next track every SECONDS, its cover the other of two. DIR keeps the covers.
import Cairo from 'cairo';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

const args = ARGV;
const option = (name, fallback) => {
    const i = args.indexOf(name);
    return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback;
};
const every = Number(option('--switch', '0'));
const dir = option('--dir', GLib.build_filenamev([GLib.get_user_runtime_dir(), 'capa-fake-player']));
GLib.mkdir_with_parents(dir, 0o700);

/** Two covers, unlike each other: a picture changing is seen to change. */
const covers = [[0.9, 0.3, 0.2], [0.2, 0.5, 0.9]].map((rgb, i) => {
    const path = GLib.build_filenamev([dir, `cover-${i}.png`]);
    const surface = new Cairo.ImageSurface(Cairo.Format.RGB24, 300, 300);
    const cr = new Cairo.Context(surface);
    cr.setSourceRGB(...rgb);
    cr.paint();
    cr.setSourceRGB(1, 1, 1);
    cr.arc(150, 150, 60 + 40 * i, 0, 2 * Math.PI);
    cr.fill();
    surface.writeToPNG(path);
    cr.$dispose();
    return `file://${path}`;
});

const TRACKS = [['Mad Technology', 'CZARFACE'], ['Second Song', 'Test Artist']];
let index = 0;
let startedAt = GLib.get_monotonic_time();
let status = 'Playing';

const ROOT = `<node><interface name="org.mpris.MediaPlayer2">
  <method name="Raise"/><method name="Quit"/>
  <property name="Identity" type="s" access="read"/>
  <property name="DesktopEntry" type="s" access="read"/>
  <property name="CanQuit" type="b" access="read"/><property name="CanRaise" type="b" access="read"/>
  <property name="HasTrackList" type="b" access="read"/>
  <property name="SupportedUriSchemes" type="as" access="read"/><property name="SupportedMimeTypes" type="as" access="read"/>
</interface></node>`;
const PLAYER = `<node><interface name="org.mpris.MediaPlayer2.Player">
  <method name="Next"/><method name="Previous"/><method name="Pause"/><method name="Play"/>
  <method name="PlayPause"/><method name="Stop"/>
  <method name="Seek"><arg type="x" direction="in"/></method>
  <method name="SetPosition"><arg type="o" direction="in"/><arg type="x" direction="in"/></method>
  <signal name="Seeked"><arg type="x"/></signal>
  <property name="PlaybackStatus" type="s" access="read"/>
  <property name="Metadata" type="a{sv}" access="read"/>
  <property name="Position" type="x" access="read"/>
  <property name="Rate" type="d" access="read"/>
  <property name="Volume" type="d" access="read"/>
  <property name="CanGoNext" type="b" access="read"/><property name="CanGoPrevious" type="b" access="read"/>
  <property name="CanPlay" type="b" access="read"/><property name="CanPause" type="b" access="read"/>
  <property name="CanSeek" type="b" access="read"/><property name="CanControl" type="b" access="read"/>
</interface></node>`;

const metadata = () => new GLib.Variant('a{sv}', {
    'mpris:trackid': new GLib.Variant('o', `/capa/fake/track/${index}`),
    'xesam:title': new GLib.Variant('s', TRACKS[index % 2][0]),
    'xesam:artist': new GLib.Variant('as', [TRACKS[index % 2][1]]),
    'xesam:album': new GLib.Variant('s', 'Fake Album'),
    'mpris:length': new GLib.Variant('x', 200_000_000),
    'mpris:artUrl': new GLib.Variant('s', covers[index % 2]),
});

const root = {
    Identity: 'Capa Fake Player', DesktopEntry: 'capa-fake-player', CanQuit: false, CanRaise: false,
    HasTrackList: false, SupportedUriSchemes: [], SupportedMimeTypes: [],
    Raise() {}, Quit() {},
};
const player = {
    get PlaybackStatus() { return status; },
    get Metadata() { return metadata().deepUnpack(); },
    get Position() { return Math.round(GLib.get_monotonic_time() - startedAt) % 200_000_000; },
    Rate: 1.0, Volume: 1.0, CanGoNext: true, CanGoPrevious: true, CanPlay: true, CanPause: true, CanSeek: true, CanControl: true,
    Next() { change(index + 1); },
    Previous() { change(Math.max(index - 1, 0)); },
    Pause() { setStatus('Paused'); },
    Play() { setStatus('Playing'); },
    PlayPause() { setStatus(status === 'Playing' ? 'Paused' : 'Playing'); },
    Stop() { setStatus('Stopped'); },
    Seek() {}, SetPosition() {},
};

const rootObject = Gio.DBusExportedObject.wrapJSObject(ROOT, root);
const playerObject = Gio.DBusExportedObject.wrapJSObject(PLAYER, player);

function changed(props) {
    playerObject.emit_property_changed && Object.entries(props).forEach(([k, v]) => playerObject.emit_property_changed(k, v));
}

function setStatus(s) {
    status = s;
    changed({PlaybackStatus: new GLib.Variant('s', s)});
}

function change(i) {
    index = i;
    startedAt = GLib.get_monotonic_time();
    changed({Metadata: metadata()});
}

const loop = new GLib.MainLoop(null, false);
Gio.bus_own_name(Gio.BusType.SESSION, 'org.mpris.MediaPlayer2.capafake', Gio.BusNameOwnerFlags.NONE,
    connection => {
        rootObject.export(connection, '/org/mpris/MediaPlayer2');
        playerObject.export(connection, '/org/mpris/MediaPlayer2');
    }, null, () => loop.quit());
if (every > 0) {
    GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, every, () => {
        change(index + 1);
        return GLib.SOURCE_CONTINUE;
    });
}
loop.run();
