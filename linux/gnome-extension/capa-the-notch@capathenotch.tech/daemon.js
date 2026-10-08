// The extension's side of the conversation with capa-daemon: it draws what
// the daemon says and asks it to do what a person asked.

import Gio from 'gi://Gio';

const BUS_NAME = 'tech.capathenotch.Daemon';
const OBJECT_PATH = '/tech/capathenotch/Daemon';

const INTERFACE = `
<node>
  <interface name="tech.capathenotch.Daemon1">
    <method name="GetState"><arg type="s" direction="out"/></method>
    <method name="Refresh"/>
    <method name="SetExpanded"><arg type="b" direction="in"/></method>
    <method name="SetProviderEnabled"><arg type="s" direction="in"/><arg type="b" direction="in"/><arg type="b" direction="out"/></method>
    <method name="SetAlertsEnabled"><arg type="b" direction="in"/></method>
    <method name="Call"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="s" direction="out"/></method>
    <method name="PlaySound"><arg type="s" direction="in"/><arg type="b" direction="out"/></method>
    <method name="SetDisplays"><arg type="s" direction="in"/></method>
    <method name="SetPreferredDisplay"><arg type="x" direction="in"/></method>
    <method name="DiagnosticReport"><arg type="s" direction="out"/></method>
    <method name="Quit"/>
    <method name="SetLanguage"><arg type="s" direction="in"/></method>
    <method name="SetCompactWindow"><arg type="s" direction="in"/></method>
    <method name="SetAlertsEnabledFor"><arg type="s" direction="in"/><arg type="b" direction="in"/></method>
    <signal name="StateChanged"><arg type="s"/></signal>
    <signal name="Alert"><arg type="s"/></signal>
    <signal name="ModuleEvent"><arg type="s"/><arg type="s"/><arg type="s"/></signal>
  </interface>
</node>`;

const Proxy = Gio.DBusProxy.makeProxyWrapper(INTERFACE);

export class DaemonClient {
    /**
     * @param {object} handlers
     * @param {(state: object) => void} handlers.onState
     * @param {(alert: object) => void} handlers.onAlert
     * @param {(running: boolean) => void} handlers.onRunning
     */
    constructor({onState, onAlert, onRunning, onModuleEvent = () => {}}) {
        this._onState = onState;
        this._onAlert = onAlert;
        this._onRunning = onRunning;
        this._onModuleEvent = onModuleEvent;
        this._proxy = null;
        this._signals = [];
        this._cancellable = new Gio.Cancellable();
        this._watch = Gio.bus_watch_name(
            Gio.BusType.SESSION, BUS_NAME, Gio.BusNameWatcherFlags.AUTO_START,
            () => this._appeared(), () => this._vanished());
        // Not waiting to be told: the daemon may already be there, and a program that is
        // not the shell may be told late. Making the proxy starts it if it is not.
        this._appeared();
    }

    _appeared() {
        if (this._proxy || this._connecting)
            return;
        this._connecting = true;
        new Proxy(Gio.DBus.session, BUS_NAME, OBJECT_PATH, (proxy, error) => {
            if (error || this._cancellable.is_cancelled()) {
                if (error)
                    console.error(`capa-the-notch: could not reach the daemon: ${error}`);
                this._connecting = false;
                return;
            }
            this._proxy = proxy;
            this._signals = [
                proxy.connectSignal('StateChanged', (_p, _sender, [json]) => this._deliver(json, this._onState)),
                proxy.connectSignal('Alert', (_p, _sender, [json]) => this._deliver(json, this._onAlert)),
                proxy.connectSignal('ModuleEvent', (_p, _sender, [module, name, data]) => {
                    try {
                        this._onModuleEvent(module, name, JSON.parse(data));
                    } catch (e) {
                        console.error(`capa-the-notch: bad module event: ${e}`);
                    }
                }),
            ];
            this._onRunning(true);
            proxy.GetStateRemote((result, err) => {
                if (!err)
                    this._deliver(result[0], this._onState);
            });
            this._connecting = false;
        }, this._cancellable);
    }

    _vanished() {
        if (this._proxy) {
            for (const id of this._signals)
                this._proxy.disconnectSignal(id);
        }
        this._signals = [];
        this._proxy = null;
        this._onRunning(false);
    }

    _deliver(json, handler) {
        try {
            handler(JSON.parse(json));
        } catch (e) {
            console.error(`capa-the-notch: could not read the daemon's message: ${e}`);
        }
    }

    /** A command for a Module. Resolves with its answer, or rejects with its error. */
    call(module, method, args = null) {
        return new Promise((resolve, reject) => {
            if (!this._proxy) {
                reject(new Error('the daemon is not running'));
                return;
            }
            this._proxy.CallRemote(module, method, JSON.stringify(args), (result, error) => {
                if (error) {
                    reject(error);
                    return;
                }
                const answer = JSON.parse(result[0]);
                if ('error' in answer)
                    reject(new Error(answer.error));
                else
                    resolve(answer.ok);
            });
        });
    }

    playSound(cue) { this._proxy?.PlaySoundRemote(cue, () => {}); }
    setDisplays(displays) { this._proxy?.SetDisplaysRemote(JSON.stringify(displays), () => {}); }
    setPreferredDisplay(id) { this._proxy?.SetPreferredDisplayRemote(id ?? -1, () => {}); }

    quit() { this._proxy?.QuitRemote(() => {}); }
    setLanguage(language) { this._proxy?.SetLanguageRemote(language, () => {}); }
    setCompactWindow(choice) { this._proxy?.SetCompactWindowRemote(choice, () => {}); }
    refresh() { this._proxy?.RefreshRemote(() => {}); }
    setExpanded(expanded) { this._proxy?.SetExpandedRemote(expanded, () => {}); }
    setProviderEnabled(provider, enabled) { this._proxy?.SetProviderEnabledRemote(provider, enabled, () => {}); }
    setAlertsEnabled(enabled) { this._proxy?.SetAlertsEnabledRemote(enabled, () => {}); }
    setAlertsEnabledFor(provider, enabled) { this._proxy?.SetAlertsEnabledForRemote(provider, enabled, () => {}); }

    destroy() {
        this._cancellable.cancel();
        if (this._watch) {
            Gio.bus_unwatch_name(this._watch);
            this._watch = 0;
        }
        this._vanished();
    }
}

