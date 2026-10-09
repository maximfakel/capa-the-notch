#!/usr/bin/env python3
"""A throwaway GNOME Shell, in a window, with CapaTheNotch in it — for trying it by hand.

  linux/scripts/test-env.py start   # build if needed, open the window, enable the extension
  linux/scripts/test-env.py stop    # close it and remove everything it made
  linux/scripts/test-env.py status

Nothing here touches the session you are in:
  - it is a nested shell (mutter-devkit) on a bus of its own;
  - every XDG directory points into $XDG_RUNTIME_DIR/capa-test-env, so the
    extension, the daemon's service file, the settings, the remembered
    capacity and the dictation model are all separate from your own;
  - the whole thing runs in one cgroup with a hard memory cap, so if the
    extension ever leaked again the kernel would kill only this window.
Your login to Codex and Claude Code (in $HOME) is read as usual; the microphone is the real one.
"""
import os, shutil, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # linux/
REPO = ROOT  # linux/, where the Cargo workspace is built
UUID = 'capa-the-notch@capathenotch.tech'
UNIT = 'capa-test-env'
BASE = os.path.join(os.environ.get('XDG_RUNTIME_DIR', '/tmp'), 'capa-test-env')
MEMORY_CAP = os.environ.get('CAPA_TEST_CAP', '3G')


def env():
    e = dict(os.environ)
    e.update({
        'XDG_DATA_HOME': f'{BASE}/data', 'XDG_CONFIG_HOME': f'{BASE}/config',
        'XDG_STATE_HOME': f'{BASE}/state', 'XDG_CACHE_HOME': f'{BASE}/cache',
    })
    return e


def scope_active():
    return subprocess.run(['systemctl', '--user', 'is-active', '--quiet', f'{UNIT}.scope']).returncode == 0


def prepare():
    for d in ('data/gnome-shell/extensions', 'data/dbus-1/services', 'data/fonts', 'config', 'state', 'cache'):
        os.makedirs(f'{BASE}/{d}', exist_ok=True)
    ext = f'{BASE}/data/gnome-shell/extensions/{UUID}'
    if os.path.lexists(ext):
        os.remove(ext)
    os.symlink(f'{ROOT}/gnome-extension/{UUID}', ext)
    daemon = f'{REPO}/target/release/capa-daemon'
    with open(f'{BASE}/data/dbus-1/services/tech.capathenotch.Daemon.service', 'w') as f:
        f.write(f'[D-BUS Service]\nName=tech.capathenotch.Daemon\nExec={daemon}\n')
    shutil.copy(f'{ROOT}/gnome-extension/{UUID}/fonts/Geist.ttf', f'{BASE}/data/fonts/Geist.ttf')
    # The settings window's icon and the entry that ties its window to it.
    shutil.copytree(f'{ROOT}/packaging/icons/hicolor', f'{BASE}/data/icons/hicolor', dirs_exist_ok=True)
    os.makedirs(f'{BASE}/data/applications', exist_ok=True)
    with open(f'{ROOT}/packaging/tech.capathenotch.Settings.desktop.in') as f:
        entry = (f.read().replace('@SETTINGS_APP@', f'{ext}/settings-app.js')
                 .replace('@ICON@', f'{BASE}/data/icons/hicolor/256x256/apps/tech.capathenotch.CapaTheNotch.png'))
    with open(f'{BASE}/data/applications/tech.capathenotch.Settings.desktop', 'w') as f:
        f.write(entry)
    with open(f'{ROOT}/packaging/tech.capathenotch.DropCatcher.desktop.in') as f:
        entry = (f.read().replace('@CATCHER_APP@', f'{ext}/drop-catcher.js')
                 .replace('@ICON@', f'{BASE}/data/icons/hicolor/256x256/apps/tech.capathenotch.CapaTheNotch.png'))
    with open(f'{BASE}/data/applications/tech.capathenotch.DropCatcher.desktop', 'w') as f:
        f.write(entry)
    subprocess.run(['glib-compile-schemas', f'{ROOT}/gnome-extension/{UUID}/schemas'], check=False)


# CAPA_TEST_HEADLESS=1: no window on your screen, and no need of one (a locked or idle desktop
# does not draw the devkit window, and a shell that is not drawn does not take input).
DISPLAY = ['--headless', '--virtual-monitor', '1280x800'] if os.environ.get('CAPA_TEST_HEADLESS') else ['--devkit']
# CAPA_TEST_SCALE=1.25 (headless only): the virtual monitor at that scale, as Settings ▸ Displays would set it,
# applied through the test shell's own DisplayConfig, for this run only (nothing is written to its settings).
SCALE = os.environ.get('CAPA_TEST_SCALE')
# CAPA_TEST_A11Y=1: an accessibility bus and registry inside the test environment, for a screen reader's view of it.
A11Y = os.environ.get('CAPA_TEST_A11Y')


def scale_monitor(address, scale):
    state = gdbus(address, '--dest', 'org.gnome.Mutter.DisplayConfig', '--object-path', '/org/gnome/Mutter/DisplayConfig',
                  '--method', 'org.gnome.Mutter.DisplayConfig.GetCurrentState').stdout
    serial = state.strip('(').split(',')[0].split()[-1]
    done = gdbus(address, '--dest', 'org.gnome.Mutter.DisplayConfig', '--object-path', '/org/gnome/Mutter/DisplayConfig',
                 '--method', 'org.gnome.Mutter.DisplayConfig.ApplyMonitorsConfig', serial, '1',
                 f'[(0, 0, {float(scale)}, 0, true, [("Meta-0", "1280x800@60.000", @a{{sv}} {{}})])]', '@a{sv} {}')
    if done.returncode:
        print(f'could not scale the monitor to {scale}: {done.stderr.strip()}')


def bus():
    """The nested session's bus address, read from its gnome-shell."""
    for pid in filter(str.isdigit, os.listdir('/proc')):
        try:
            cmd = open(f'/proc/{pid}/cmdline').read().split('\0')
            if cmd[:1] == ['gnome-shell'] and ('--devkit' in cmd or '--headless' in cmd):
                for item in open(f'/proc/{pid}/environ').read().split('\0'):
                    if item.startswith('DBUS_SESSION_BUS_ADDRESS='):
                        return item.split('=', 1)[1]
        except OSError:
            continue
    return None


def gdbus(address, *args):
    e = dict(os.environ, DBUS_SESSION_BUS_ADDRESS=address)
    return subprocess.run(['gdbus', 'call', '--session', *args], env=e, capture_output=True, text=True, timeout=20)


def call(address, module, method, args):
    import json
    return subprocess.run(
        ['busctl', '--user', 'call', 'tech.capathenotch.Daemon', '/tech/capathenotch/Daemon',
         'tech.capathenotch.Daemon1', 'Call', 'sss', module, method, json.dumps(args)],
        env=dict(os.environ, DBUS_SESSION_BUS_ADDRESS=address), capture_output=True, text=True, timeout=30)


def start():
    if scope_active():
        print('already running; `stop` first')
        return
    if not os.path.exists(f'{REPO}/target/release/capa-daemon'):
        print('building the daemon (release)…')
        subprocess.run(['cargo', 'build', '--release', '-p', 'capa-daemon'], cwd=REPO, check=True)
    # A scope the kernel killed stays 'failed' and keeps its name until it is cleared.
    subprocess.run(['systemctl', '--user', 'reset-failed', f'{UNIT}.scope'], capture_output=True)
    shutil.rmtree(BASE, ignore_errors=True)
    prepare()
    log = open(f'{BASE}/shell.log', 'w')
    shell = ['dbus-run-session', '--', 'gnome-shell', *DISPLAY, '--wayland', '--unsafe-mode']
    session = env()
    if A11Y:
        # An accessibility bus of the test shell's own, in its scope, with its socket among its files: the
        # shell and everything it starts are pointed at it, so the desktop's own (and the systemd that
        # activates its registry) is never asked. The registry it starts has no display to reach.
        # Started inside the test shell's own session bus, so what it activates knows no other.
        session['AT_SPI_BUS_ADDRESS'] = f'unix:path={BASE}/a11y-bus'
        shell = ['dbus-run-session', '--', 'sh', '-c', 'env -u DISPLAY -u WAYLAND_DISPLAY dbus-daemon --nofork --nopidfile '
                 f'--config-file=/usr/share/defaults/at-spi2/accessibility.conf --address=unix:path={BASE}/a11y-bus & '
                 f'for i in 1 2 3 4 5 6 7 8 9 10; do [ -S {BASE}/a11y-bus ] && break; sleep 0.2; done; exec "$@"',
                 'sh', *shell[2:]]
    subprocess.Popen(
        ['systemd-run', '--user', '--scope', '-q', f'--unit={UNIT}', '-p', f'MemoryMax={MEMORY_CAP}',
         '-p', 'MemorySwapMax=0', *shell],
        env=session, stdout=log, stderr=log, start_new_session=True)
    address = None
    for _ in range(40):
        time.sleep(0.5)
        address = bus()
        if address:
            break
    if not address:
        print('the shell did not come up; see', f'{BASE}/shell.log')
        return
    time.sleep(6)
    if SCALE and os.environ.get('CAPA_TEST_HEADLESS'):
        scale_monitor(address, SCALE)
        time.sleep(2)
    # A fresh settings store knows no enabled extensions: enable ours, and put the overview away.
    gdbus(address, '--dest', 'org.gnome.Shell', '--object-path', '/org/gnome/Shell', '--method', 'org.gnome.Shell.Eval',
          f"Main.extensionManager.enableExtension('{UUID}'); Main.overview.hide(); 1")
    time.sleep(3)
    # Everything on, so every Module can be tried by hand; Providers as a fresh install has them.
    for key in ('musicEnabled', 'teleprompterEnabled', 'shelfEnabled', 'dictationEnabled', 'alertsEnabled',
                'shelfKeepsText', 'shelfTakesClipboardImages'):
        call(address, 'settings', 'set', {'key': key, 'value': True})
    print(f'The test shell is open in its own window (memory capped at {MEMORY_CAP}).')
    print(f'  everything it keeps is in {BASE}; `linux/scripts/test-env.py stop` removes it.')
    print(f'  its log: {BASE}/shell.log')


def stop():
    subprocess.run(['systemctl', '--user', 'stop', f'{UNIT}.scope'], capture_output=True)
    subprocess.run(['systemctl', '--user', 'reset-failed', f'{UNIT}.scope'], capture_output=True)
    shutil.rmtree(BASE, ignore_errors=True)
    print('stopped; the test environment is gone')


def status():
    print('running' if scope_active() else 'not running')


if __name__ == '__main__':
    {'start': start, 'stop': stop, 'status': status}[sys.argv[1] if len(sys.argv) > 1 else 'status']()
