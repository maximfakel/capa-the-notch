#!/usr/bin/env python3
"""Drives CapaTheNotch in the throwaway shell (linux/scripts/test-env.py) with a virtual mouse and keyboard.

  linux/scripts/dev/shell-test.py            # start the test shell if needed, run every scenario, say what held
  linux/scripts/dev/shell-test.py --keep     # leave the test shell open afterwards (it is closed if this opened it)

The shell runs with Eval and Screenshot allowed (--unsafe-mode); input is made by virtual devices created
inside it, so nothing here touches the session you are in. Pictures go to $XDG_RUNTIME_DIR/capa-test-env/shots.
"""
import importlib.util, json, os, re, subprocess, sys, time

# The harness needs no window of its own, and a locked desktop would starve one.
os.environ.setdefault('CAPA_TEST_HEADLESS', '1')
# test-env.py is loaded as a module; it leaves no bytecode beside it.
sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location('test_env', os.path.join(HERE, '..', 'test-env.py'))
env = importlib.util.module_from_spec(spec)
spec.loader.exec_module(env)

UUID = env.UUID
EXT = f"Main.extensionManager.lookup('{UUID}').stateObj"
SCENE = f'{EXT}._surface.scene'
SHOTS = os.path.join(env.BASE, 'shots')

results = []
address = None


def ev(js, timeout=20):
    """Evaluates `js` in the test shell; returns its value (JSON-decoded when it is), or raises."""
    out = env.gdbus(address, '--dest', 'org.gnome.Shell', '--object-path', '/org/gnome/Shell',
                    '--method', 'org.gnome.Shell.Eval', js)
    text = out.stdout.strip()
    m = re.match(r"^\((true|false), '(.*)'\)$", text, re.S)
    if not m:
        raise RuntimeError(f'Eval gave {text!r} {out.stderr!r}')
    ok = m.group(1) == 'true'
    # gdbus prints a GVariant string: its own escapes first, then what Eval put in it (JSON).
    payload = m.group(2).replace("\\'", "'").replace('\\\\', '\\')
    try:
        value = json.loads(payload)
    except ValueError:
        value = payload
    if not ok:
        raise RuntimeError(value)
    return value


def shot(name):
    os.makedirs(SHOTS, exist_ok=True)
    path = os.path.join(SHOTS, f'{name}.png')
    env.gdbus(address, '--dest', 'org.gnome.Shell.Screenshot', '--object-path', '/org/gnome/Shell/Screenshot',
              '--method', 'org.gnome.Shell.Screenshot.Screenshot', 'false', 'false', path)
    return path


def check(name, ok, detail=''):
    results.append((name, bool(ok), detail))
    print(('PASS ' if ok else 'FAIL ') + name + (f'  [{detail}]' if detail and not ok else ''))


def settle(seconds=1.2):
    time.sleep(seconds)


# MARK: the virtual devices, made once inside the shell

def devices():
    ev("""
        globalThis.__C = imports.gi.Clutter;
        const seat = (global.stage.context?.get_backend?.() ?? __C.get_default_backend()).get_default_seat();
        globalThis.__mouse = seat.create_virtual_device(__C.InputDeviceType.POINTER_DEVICE);
        globalThis.__keys = seat.create_virtual_device(__C.InputDeviceType.KEYBOARD_DEVICE);
        globalThis.__us = () => imports.gi.GLib.get_monotonic_time();
        'ok'""")


def move(x, y):
    ev(f'__mouse.notify_absolute_motion(__us(), {x}, {y}); 1')


def press(button=1):
    # A hand is never quite still: the pointer's focus follows a motion, and a shell not drawing does not catch up without one.
    ev('const [__x, __y] = global.get_pointer(); __mouse.notify_absolute_motion(__us(), __x + 1, __y); 1')
    time.sleep(0.2)
    ev(f'__mouse.notify_button(__us(), {button}, __C.ButtonState.PRESSED); __mouse.notify_button(__us(), {button}, __C.ButtonState.RELEASED); 1')


def key(keyval):
    ev(f'__keys.notify_keyval(__us(), {keyval}, __C.KeyState.PRESSED); __keys.notify_keyval(__us(), {keyval}, __C.KeyState.RELEASED); 1')


def scroll(dx, dy=0):
    ev(f'__mouse.notify_scroll_continuous(__us(), {dx}, {dy}, __C.ScrollSource.FINGER, __C.ScrollFinishFlags.NONE); 1')


def scene(expr):
    return ev(f'JSON.stringify({SCENE}.{expr})')


def hit(id_):
    """A region the scene drew last, on the screen: {x, y, w, h}, or None."""
    found = json.loads(ev(f"JSON.stringify({SCENE}.hits.find(h => h.id === '{id_}') ?? null)") or 'null')
    if found is None:
        return None
    origin = json.loads(ev(f"JSON.stringify({EXT}._surface.actor.x)"))
    return {**found, 'x': origin + found['x']}


def strip_away_from_the_clock():
    """A point on the strip that is not the time: the time opens the calendar, the rest pins."""
    strip, clock = hit('strip'), hit('clock')
    if strip is None:
        return 600, 19
    right = clock['x'] if clock else strip['x'] + strip['w'] / 2 - 40
    return round(strip['x'] + (right - strip['x']) / 2), 19


# MARK: scenarios

def on_the_desktop():
    """A nested shell with no window in it falls into the overview, where a click lands on a window's picture."""
    for _ in range(20):
        if ev('Main.overview.visible') is not True:
            return
        ev('Main.overview.hide(); 1')
        settle(0.5)


def close_the_welcome():
    """A fresh shell opens the onboarding window, when the state first arrives; it takes the keyboard, so it goes."""
    gone = "global.get_window_actors().forEach(a => { if (a.meta_window.get_wm_class() == 'tech.capathenotch.Settings') a.meta_window.delete(global.get_current_time()) }); 1"
    for _ in range(24):
        found = json.loads(ev("JSON.stringify(global.get_window_actors().some(a => a.meta_window.get_wm_class() == 'tech.capathenotch.Settings'))"))
        if found:
            ev(gone)
            settle(1.0)
            return
        settle(0.5)


def extension_is_active():
    info = env.gdbus(address, '--dest', 'org.gnome.Shell.Extensions', '--object-path', '/org/gnome/Shell/Extensions',
                     '--method', 'org.gnome.Shell.Extensions.GetExtensionInfo', UUID).stdout
    check('the extension is active', "'state': <1.0>" in info, info[:80])


def hover_opens_and_leaving_closes():
    move(100, 600)
    settle(0.6)
    check('closed at rest', scene('expanded') == 'false')
    move(640, 19)
    # Three beats of 100 ms open it, 0.2 to 0.3 s from the first: look well before.
    settle(0.05)
    check('a passing pointer has not asked for anything yet', scene('expanded') == 'false')
    settle(1.15)
    check('the pointer settled on the strip: it opens', scene('expanded') == 'true')
    settle(0.8)
    shot('open')
    move(100, 600)
    settle(1.2)
    check('the pointer gone: it closes', scene('expanded') == 'false')


def growth_near_the_strip():
    move(640, 38 + 40)
    settle(1.0)
    check('near the strip it grows a little', scene('pointerNear') == 'true')
    move(100, 600)
    settle(0.8)


def click_pins_and_escape_lets_go():
    move(640, 19)
    settle(0.8)
    move(*strip_away_from_the_clock())
    settle(0.2)
    press()
    settle(0.4)
    why = ev("let [x,y]=global.get_pointer(); [x,y,String(global.stage.get_actor_at_pos(__C.PickMode.REACTIVE,x,y)).slice(0,40), " + EXT + "._surface.actor.reactive, " + EXT + "._dnd._dragging, JSON.stringify(global.get_window_actors().map(a => a.meta_window.get_title())), global.display.focus_window?.get_title()].join(' ')")
    check('a click pins it', scene('pinned') == 'true', why)
    move(100, 600)
    settle(1.0)
    check('a pinned surface stays when the pointer leaves', scene('expanded') == 'true')
    key(0xff1b)  # Escape
    settle(0.6)
    check('Escape lets it go', scene('pinned') == 'false' and scene('expanded') == 'false')


def pages_and_the_switcher():
    pages = json.loads(scene('model.pages'))
    check('every Module that is on has its page', pages[0] == 'capacity' and len(pages) >= 4, str(pages))
    move(640, 19)
    settle(1.0)
    check('open for the pages', scene('expanded') == 'true')
    height = json.loads(scene('openHeight'))
    move(640, height - 18)
    settle(1.0)
    check('near the bottom the dots become buttons', scene('controlsShown') == 'true')
    shot('switcher')
    # a swipe right to left turns to the next page
    # a touchpad sends many small smooth deltas; a big one would be read as a wheel notch
    for _ in range(12):
        scroll(6)
    settle(1.0)
    check('a swipe turned the page', scene('selected') != '"capacity"', scene('selected'))
    # The arrows reach only a pinned surface, which has the keyboard (Swift's key window).
    move(640, 19)
    settle(0.6)
    move(*strip_away_from_the_clock())
    settle(0.2)
    press()
    settle(0.6)
    key(0xff51)  # Left
    settle(0.8)
    check('the left arrow turns back', scene('selected') == '"capacity"', scene('selected'))
    key(0xff1b)  # Escape
    settle(0.6)
    move(640, 19)
    settle(1.0)
    move(640, height - 18)
    settle(1.0)
    move(100, 600)
    settle(1.2)


def btn(state):
    ev(f'__mouse.notify_button(__us(), 1, __C.ButtonState.{state}); 1')


def shelf_files():
    state = ev("JSON.stringify(" + EXT + "._state?.modules?.shelf?.view ?? {})")
    return state


def a_file_dropped_from_another_program():
    """A real Wayland drag from a GTK window to the surface: it opens on the Shelf, takes the file, Kapa eats it."""
    # The window that takes the drop is started with the Shelf; a fresh shell may not have it up yet.
    for _ in range(40):
        if json.loads(ev(f"JSON.stringify({EXT}._dnd._actions.list_actions().length)")) > 0:
            break
        settle(0.5)
    source = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'dnd-source.js')
    open('/tmp/capa-dragme.txt', 'w').write('hello')
    # The welcome of a fresh shell is in the way of the source window.
    ev("global.get_window_actors().forEach(a => { if (a.meta_window.get_wm_class() == 'tech.capathenotch.Settings') a.meta_window.delete(global.get_current_time()) }); 1")
    settle(1.0)
    ev(f"imports.gi.GLib.spawn_command_line_async('gjs -m {source}'); 1")
    settle(3.0)
    on_the_desktop()
    shown = ev("JSON.stringify(global.get_window_actors().map(a => a.meta_window.get_title()))")
    check('the window to drag from is there', 'dnd-source' in shown, shown)
    before = json.loads(ev("JSON.stringify(" + EXT + "._state?.modules?.shelf?.view?.files?.length ?? 0)"))
    # A window that appears under a pointer that does not move has not been entered: come from elsewhere.
    move(300, 700)
    settle(0.3)
    move(640, 416)
    settle(0.4)
    btn('PRESSED')
    settle(0.2)
    for y in (380, 300, 220, 150, 100, 70):
        move(640, y)
        settle(0.25)
    settle(0.8)
    opened = scene('expanded') == 'true' and scene('selected') == '"shelf"'
    check('carried to the surface it opens on the Shelf', opened, scene('selected'))
    # The icon of what is carried is drawn above the surface, not under it.
    order = json.loads(ev("const u = Main.layoutManager.uiGroup, k = u.get_children(); JSON.stringify([k.indexOf(" + EXT + "._surface.actor), k.indexOf(global.compositor.get_feedback_group())])"))
    check('the dragged icon stays above the surface', order[0] >= 0 and order[1] > order[0], str(order))
    shot('drop-over')
    # Kapa watches the file: its eyes go to the side the file is on.
    yaw = "JSON.stringify(+(" + EXT + "._surface.scene.engines.get('shelf-drop')?._yaw ?? 0).toFixed(2))"
    move(560, 130)
    settle(0.8)
    left = json.loads(ev(yaw))
    move(720, 130)
    settle(0.8)
    right = json.loads(ev(yaw))
    check('Kapa looks at the file, on either side', left < -0.1 and right > 0.1, f'{left} / {right}')
    move(640, 100)
    settle(0.3)
    btn('RELEASED')
    settle(2.5)
    after = json.loads(ev("JSON.stringify(" + EXT + "._state?.modules?.shelf?.view?.files?.length ?? 0)"))
    check('the file is in the Shelf', after == before + 1, f'{before} -> {after}')
    check('the surface is let go of', ev(f"({EXT}._surface.actor.reactive)") is True)
    ev("global.get_window_actors().forEach(a=>{ if(a.meta_window.get_title()=='dnd-source') a.meta_window.delete(global.get_current_time())}); 1")
    settle(0.5)


def page_buttons():
    """The dots become buttons: lit under the pointer, pressed while down, taken on the release; the keyboard reaches them."""
    scene_ = EXT + "._surface.scene"
    ev(f"{scene_}.select('capacity'); 1")
    move(100, 600)
    settle(0.6)
    move(640, 19)
    settle(1.4)
    height = json.loads(scene('openHeight'))
    move(640, height - 18)
    settle(1.2)
    hit = json.loads(ev(f"JSON.stringify({scene_}.hits.find(h => h.id === 'page:music') ?? null)") or 'null')
    check('the music button is there', hit is not None)
    if hit is None:
        return
    origin = json.loads(ev(f"JSON.stringify({EXT}._surface.actor.x)"))
    px, py = origin + hit['x'] + hit['w'] / 2, hit['y'] + hit['h'] / 2
    state = lambda field: json.loads(ev(f"JSON.stringify(+{scene_}.switcher.get('music').{field}.value.toFixed(2))"))
    move(px, py)
    settle(0.6)
    check('the button under the pointer lights', state('lit') > 0.9, str(state('lit')))
    shot('switcher-lit')
    btn('PRESSED')
    settle(0.4)
    check('and is pressed while the button is down', state('press') > 0.9, str(state('press')))
    check('a press alone does not turn the page', scene('selected') == '"capacity"')
    btn('RELEASED')
    settle(1.0)
    check('the release turns it', scene('selected') == '"music"', scene('selected'))
    # released away from the button, nothing turns
    btn('PRESSED')
    settle(0.2)
    move(px + 200, py - 80)
    settle(0.3)
    btn('RELEASED')
    settle(0.6)
    check('a release away from the button does not turn it', scene('selected') == '"music"')
    # the keyboard: pinned it hears keys; Tab walks the buttons, Return takes one
    ev(f"{scene_}.select('capacity'); 1")
    settle(0.8)
    move(640, 19)
    settle(0.6)
    move(*strip_away_from_the_clock())
    settle(0.2)
    press()
    settle(0.4)
    move(640, height - 18)
    settle(1.0)
    # The cards' buttons come first (`.focusable()`), then the page buttons.
    cards = json.loads(ev(f"JSON.stringify({scene_}.hits.filter(h => h.focusable && !h.id.startsWith('page:')).map(h => h.id))"))
    key(0xff09)  # Tab
    settle(0.3)
    first = scene('focused')
    for _ in range(len(cards) + 1):
        key(0xff09)
        settle(0.3)
    focus = scene('focusedPage')
    check('Tab walks the cards\' buttons, then the page buttons', focus == '"music"' and json.loads(first) == (cards + ['page:capacity'])[0],
          f'{first} then {focus} over {cards}')
    key(0xff0d)  # Return
    settle(1.0)
    check('Return takes the one it is on', scene('selected') == '"music"', scene('selected'))
    key(0xff1b)
    settle(0.6)
    move(100, 600)
    settle(1.2)


def what_a_screen_reader_finds():
    """Over what is drawn, objects a screen reader reads: names and roles as Swift's, none of them taking the pointer."""
    scene_ = EXT + "._surface.scene"
    ev(f"{scene_}.select('capacity'); 1")
    move(640, 19)
    settle(0.6)
    move(*strip_away_from_the_clock())
    settle(0.2)
    press()
    settle(0.6)
    height = json.loads(scene('openHeight'))
    move(640, height - 18)
    settle(1.2)
    said = json.loads(ev(f"""const a = {EXT}._surface.actor, Atk = imports.gi.Atk;
        JSON.stringify(a.get_children().filter(c => c.constructor.name === 'CapaAccessibleNode' && c.visible).map(c => {{
            const [x, y] = c.get_transformed_position();
            const hit = global.stage.get_actor_at_pos(imports.gi.Clutter.PickMode.REACTIVE, Math.round(x + c.width / 2), Math.round(y + c.height / 2));
            return {{at: [Math.round(x), Math.round(y), c.width, c.height, String(hit).slice(0, 60)], name: c.accessible_name, role: c.accessible_role === Atk.Role.PAGE_TAB ? 'tab' : c.accessible_role === Atk.Role.LABEL ? 'label' : c.accessible_role === Atk.Role.PUSH_BUTTON ? 'button' : String(c.accessible_role),
                selected: c.get_accessible().ref_state_set().contains_state(Atk.StateType.SELECTED), reactive: c.reactive, picked: hit === a}};
        }}))"""))
    # What the scene drew, in whatever language the shell speaks: the objects say the same, in the same order.
    nodes = json.loads(ev(f"JSON.stringify({scene_}.accessibleNodes().filter(n => n.id !== 'strip'))"))
    pages = json.loads(scene('model.pages'))
    tabs = [n for n in said if n['role'] == 'tab']
    card = [n['id'] for n in nodes if n['id'].startswith(('refresh:', 'connect:', 'open-settings'))]
    check('a screen reader finds the page buttons, the cards\' buttons and words, none taking the pointer',
          [n['name'] for n in said] == [n['label'] for n in nodes] and [n['role'] for n in said] == [n['role'] for n in nodes]
          and len(tabs) == len(pages) and [t['selected'] for t in tabs].count(True) == 1 and tabs[0]['selected']
          and card and any(n['role'] == 'label' for n in said)
          and not any(n['reactive'] for n in said) and all(n['picked'] for n in said),
          json.dumps([n for n in said if not n['picked'] or n['reactive']], ensure_ascii=False)[:300])
    # Tab moves the keyboard among the controls: the object over the one it is on is focused, and
    # only it, so a screen reader follows; the strip, a toggle, is on while the surface is open.
    key(0xff09)
    settle(0.6)
    states = json.loads(ev(f"""const a = {EXT}._surface.actor, Atk = imports.gi.Atk, sc = {scene_};
        const on = (o, s) => o.get_accessible().ref_state_set().contains_state(s);
        JSON.stringify({{focused: a.get_children().filter(c => c.constructor.name === 'CapaAccessibleNode' && c.visible
                            && on(c, Atk.StateType.FOCUSED)).map(c => [c.accessible_name, on(c, Atk.StateType.ENABLED)]),
                        want: sc.hits.find(h => h.id === sc.focused)?.label ?? null, checked: on(a, Atk.StateType.CHECKED)}})"""))
    check('the control Tab is on is the one a screen reader is told has the focus, and it is enabled; the strip is on',
          states['want'] is not None and states['focused'] == [[states['want'], True]] and states['checked'],
          json.dumps(states, ensure_ascii=False)[:200])
    key(0xff1b)
    settle(0.6)
    move(100, 600)
    settle(1.2)


def reduce_motion():
    """Reduce Motion: the surface opens on a short ease, with no spring's overshoot."""
    scene_ = EXT + "._surface.scene"

    def widest():
        move(100, 600)
        settle(1.4)
        ev("globalThis.__w = 0; globalThis.__t = imports.gi.GLib.timeout_add(0, 16, () => { __w = Math.max(__w, " + scene_ + ".width.value); return true }); 1")
        move(640, 19)
        settle(1.6)
        ev("imports.gi.GLib.source_remove(__t); 1")
        return json.loads(ev('JSON.stringify(__w)')), json.loads(scene('openWidth'))

    ev(f"{scene_}.setModel({{reduceMotion: false}}); 1")
    peak, final = widest()
    check('with motion the spring overshoots', peak > final + 1, f'{peak:.1f} vs {final:.1f}')
    ev(f"{scene_}.setModel({{reduceMotion: true}}); 1")
    peak, final = widest()
    check('under Reduce Motion it does not', peak <= final + 0.5, f'{peak:.1f} vs {final:.1f}')
    ev(f"{scene_}.setModel({{reduceMotion: false}}); 1")
    move(100, 600)
    settle(1.0)


def kapa_follows_the_pointer():
    """The pointer over Kapa draws its eyes to it, and a tap boops it and says so."""
    ev(f"{EXT}._surface.scene.select('capacity'); 1")
    move(100, 600)
    settle(0.6)
    move(640, 19)
    settle(1.4)
    move(640, 150)
    settle(0.8)
    # A card's Kapa, or, with no Provider on (a fresh test shell), the one that says hello.
    # Each card has a Kapa of its own, keyed by its Provider and size (`capacity-card:<provider>:<size>`):
    # drawn by the surface the last time it drew, or on a layer of her own (`scene.layers`).
    which = json.loads(ev("const s = " + EXT + "._surface.scene; JSON.stringify([...s.engines.keys()].find(k => (k.startsWith('capacity-card:') || k === 'hello') && (s.engines.get(k).drawnInFrame === s._drawCount || s.layers?.get('kapa:' + k)?.replay)) ?? null)"))
    frame = json.loads(ev("JSON.stringify(" + EXT + f"._surface.scene.engines.get('{which}')?.frame ?? null)") or 'null') if which else None
    check('the page has its Kapa', frame is not None)
    if frame is None:
        return
    origin = json.loads(ev(f"JSON.stringify({EXT}._surface.actor.x)"))
    cx, cy = origin + frame['x'] + frame['width'] / 2, frame['y'] + frame['height'] / 2
    yaw = "JSON.stringify(+(" + EXT + "._surface.scene.engines.get('" + which + "')._yaw).toFixed(2))"
    move(cx - 9, cy)
    settle(0.9)
    left = json.loads(ev(yaw))
    move(cx + 9, cy)
    settle(0.9)
    right = json.loads(ev(yaw))
    check('Kapa follows the pointer over it', left < -0.1 and right > 0.1, f'{left} / {right}')
    move(640, 150)
    # The eyes ease back, they do not jump: give them the time they take.
    settle(2.0)
    check('and looks ahead again when it leaves', abs(json.loads(ev(yaw))) < 0.05,
          ev("const e = " + EXT + "._surface.scene.engines.get('" + which + "'); const s = " + EXT + "._surface.scene; JSON.stringify({yaw: e._yaw, hover: e.hover, expanded: s.expanded, sp: s.shapePointer, due: s.kapaDue - s.now, drawn: e.drawnInFrame, count: s._drawCount, moving: e._moving})"))
    ev("globalThis.__snd = []; const a = " + EXT + "._surface.scene.actions; const o = a.sound; a.sound = c => { __snd.push(c); return o?.(c) }; 1")
    move(cx, cy)
    settle(0.6)
    press()
    settle(0.5)
    check('a tap boops it, with its sound', 'kapaTapped' in json.loads(ev('JSON.stringify(__snd)')))
    move(100, 600)
    settle(0.8)


def start_player(*args):
    """A player of the test shell's own (fake-player.js), started inside it: its MPRIS name is on the shell's bus."""
    player = os.path.join(HERE, 'fake-player.js')
    extra = ''.join(f", '{a}'" for a in args)
    ev(f"globalThis.__player?.force_exit(); globalThis.__player = imports.gi.Gio.Subprocess.new(['gjs', '-m', '{player}'{extra}], 0); 1")


def stop_player():
    ev("globalThis.__player?.force_exit(); globalThis.__player = null; 1")


def the_row_over_a_covering_window():
    """A window covering the screen comes and goes: the music row fades away and back as the shape moves on the closing spring."""
    surface = f'{EXT}._surface'
    move(100, 600)
    settle(1.0)
    start_player()
    try:
        for _ in range(30):
            if json.loads(scene('compactRow()?.module.id ?? null')) == 'music':
                break
            settle(0.5)
        settle(1.5)
        bar = json.loads(scene('geometry.barHeight'))
        full = json.loads(scene('height.value'))
        check('a playing track is a row under the strip', full > bar + 20 and scene('atRest') == 'true', f'{full} over {bar}')
        # Every 8 ms: the shape's height, the row's share, and whether the row's layer is showing.
        ev("globalThis.__seen = []; globalThis.__watch = imports.gi.GLib.timeout_add(0, 8, () => { const s = " + SCENE
           + "; __seen.push([s.height.value, s.shownRow()?.share ?? 0, " + surface
           + "._layers.get('row')?.area.visible ?? false, s.layers.has('row')]); return true }); 1")
        ev(f'{surface}.setFullscreen(true); 1')
        settle(1.4)
        away = json.loads(ev('const a = __seen; globalThis.__seen = []; JSON.stringify(a)'))
        ev(f'{surface}.setFullscreen(false); 1')
        settle(1.4)
        ev('imports.gi.GLib.source_remove(__watch); 1')
        back = json.loads(ev('JSON.stringify(__seen)'))
        between = lambda seen: [h for h, *_ in seen if bar + 2 < h < full - 2]
        check('a covering window: the shape closes up through the heights between, to the strip',
              len(between(away)) >= 5 and abs(away[-1][0] - bar) < 0.01, f'{len(between(away))} between, ends at {away[-1][0]:.1f}')
        fading = [v for _, v, *_ in away if 0 < v < 1]
        gone = next((i for i, (_, v, *_) in enumerate(away) if v == 0), None)
        check('the row fades as it goes, and is gone well before the shape stops',
              fading and gone is not None and gone < len(away) / 2 and all(v == 0 for _, v, *_ in away[gone:]),
              f'{len(fading)} fading, gone at {gone} of {len(away)}')
        # Until the first frame the layer keeps drawing the row as it was; from the first that moves, the surface alone.
        first = next((i for i, (h, v, *_) in enumerate(away) if h < full or v < 1), len(away))
        check('and is drawn by the surface alone while it moves: its layer is put away',
              first < len(away) and all(not shown and not used for _, _, shown, used in away[first:]),
              str([r for r in away[first:] if r[2] or r[3]][:3]))
        check('the window gone: the shape grows back through the heights between, the row with it',
              len(between(back)) >= 5 and abs(back[-1][0] - full) < 0.01 and back[-1][1] == 1
              and any(0 < v < 1 for _, v, *_ in back), f'{len(between(back))} between, ends at {back[-1][:2]}')
        check('at rest again, the row is back on its layer', back[-1][2] and back[-1][3], str(back[-1]))
    finally:
        stop_player()
        ev(f'{surface}.setFullscreen(false); 1')
    # The player gone, its row goes too (after the pause it is kept for).
    for _ in range(40):
        if json.loads(scene('compactRow()?.module.id ?? null')) is None:
            break
        settle(0.5)


def the_top_bar_button():
    """Kapa's silhouette in the top bar (`MenuBarExtra`): a click opens its three items, Escape closes them."""
    button = "Main.panel.statusArea['capa-the-notch']"
    check('the top bar has the button', ev(f"({button} ? 'yes' : 'no')") == 'yes')
    box = json.loads(ev(f"const [x, y] = {button}.get_transformed_position(); JSON.stringify({{x, y, w: {button}.width, h: {button}.height}})"))
    move(round(box['x'] + box['w'] / 2), round(box['y'] + box['h'] / 2))
    settle(0.4)
    press()
    settle(0.8)
    check('a click opens its menu', ev(f"({button}.menu.isOpen ? 'yes' : 'no')") == 'yes')
    items = json.loads(ev(f"JSON.stringify({button}.menu._getMenuItems().filter(i => i.label?.text).map(i => i.label.text))"))
    rows = json.loads(ev(f"JSON.stringify({button}.menu._getMenuItems().length)"))
    check('with three items and the two dividers', len(items) == 3 and rows == 5, f'{items} in {rows}')
    shot('menu')
    key(0xff1b)
    settle(0.8)
    check('Escape closes the menu', ev(f"({button}.menu.isOpen ? 'yes' : 'no')") == 'no')
    move(100, 600)
    settle(1.0)


def the_clock_opens_the_calendar():
    """The time in the strip covers the desktop's clock: a click on it opens the calendar, which the surface keeps clear of."""
    calendar = 'Main.panel.statusArea.dateMenu.menu'
    is_open = lambda: ev(f"({calendar}.isOpen ? 'yes' : 'no')") == 'yes'
    move(100, 600)
    settle(1.2)
    clock = hit('clock')
    check('the strip shows the time', clock is not None)
    if clock is None:
        return
    cx, cy = round(clock['x'] + clock['w'] / 2), round(clock['h'] / 2)
    move(cx, cy)
    press()
    settle(1.0)
    check('a click on the time opens the calendar', is_open())
    check('and does not pin the surface', scene('pinned') == 'false')
    # The pointer resting on the time does not open the surface over the calendar, nor close it.
    move(cx + 2, cy)
    settle(1.2)
    check('the surface stays closed while the calendar is open', scene('expanded') == 'false' and is_open())
    above = ev(f"const g = Main.uiGroup; (g.get_children().indexOf({calendar}.actor) > g.get_children().indexOf({EXT}._surface.actor) ? 'yes' : 'no')")
    check('the calendar is drawn over the surface', above == 'yes')
    shot('calendar')
    key(0xff1b)
    settle(0.8)
    check('Escape closes the calendar', not is_open())
    # Away from the time, the strip pins as before.
    move(*strip_away_from_the_clock())
    press()
    settle(0.8)
    check('a click beside the time still pins', scene('pinned') == 'true' and not is_open())
    key(0xff1b)
    settle(0.6)
    move(100, 600)
    settle(1.0)


def no_runaway():
    before = ev("imports.system.gc && 1") if False else None
    mem = subprocess.run(['systemctl', '--user', 'show', f'{env.UNIT}.scope', '-p', 'MemoryCurrent'],
                         capture_output=True, text=True).stdout
    current = int(mem.split('=')[1]) / 1048576
    check('the whole test shell stays under 1.5 GB', current < 1500, f'{current:.0f} MB')


def main():
    global address
    opened_here = False
    if not env.scope_active():
        env.start()
        opened_here = True
    address = env.bus()
    if not address:
        print('no test shell to talk to')
        sys.exit(2)
    ev("Main.overview.hide(); 1")
    devices()
    # A fresh shell with no window starts in the overview; until it is let go of by a key, clicks do not land.
    settle(1.0)
    key(0xff1b)
    settle(1.0)
    # GNOME 51 greets a fresh shell with its own modal "Welcome" dialog, which takes every click.
    ev("Main.layoutManager.modalDialogGroup.get_children().forEach(c => { if (c.visible) (c._delegate ?? c).close?.(); }); 1")
    settle(1.0)
    close_the_welcome()
    for scenario in (extension_is_active, hover_opens_and_leaving_closes, growth_near_the_strip,
                     click_pins_and_escape_lets_go, pages_and_the_switcher, page_buttons, what_a_screen_reader_finds, reduce_motion, kapa_follows_the_pointer, the_row_over_a_covering_window, a_file_dropped_from_another_program,
                     the_top_bar_button, the_clock_opens_the_calendar, no_runaway):
        try:
            on_the_desktop()
            scenario()
        except Exception as error:  # a scenario that cannot run is a failure, said plainly
            check(scenario.__name__, False, str(error)[:160])
    failed = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(failed)} of {len(results)} held. Pictures: {SHOTS}")
    if opened_here and '--keep' not in sys.argv:
        env.stop()
    sys.exit(1 if failed else 0)


main()
