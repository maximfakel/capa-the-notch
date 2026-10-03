# Coucou's Mochi: how a notch character is built, and what Capacity Notch could take from it

2026-10-01. Studied: [Louis-CFM/coucou](https://github.com/Louis-CFM/coucou) at commit
`835421c7fff260f0f0be48927591b96bfad81cad` (2026-10-01 00:48 +0200, all 34 commits of the
repository's history). Compared against Capacity Notch at `1f747e6`.

Russian translation: `docs/research/coucou-character.ru.md`. If the two disagree, this file is right.

## How to read the citations

- `C:File.swift:12-34` is `NotchBuddy/Sources/App/File.swift` in coucou at `835421c`. Other coucou
  paths are given from the repository root, still at `835421c`, e.g. `C:docs/SPEC.md:112`.
- `CN:path:12` is this repository at `1f747e6`.
- Everything here comes from reading source. Nothing was built or run. Timings are the constants
  in the code, not measured on screen. CPU figures are not given because none were measured.
- **Uncertain** marks inference rather than something read in code.

## Summary

- **Mochi is drawn entirely in code.** It is a SwiftUI `Canvas` inside `TimelineView(.animation)`,
  about 60 fps. There are no images, no Lottie, no Rive, no SpriteKit and no Metal
  (`C:BotCanvasView.swift:13-38`, `C:CLAUDE.md` "Rules"). The body is a superellipse with
  exponent 2.7, sampled at 73 points. The eyes are placed as if on a rotating sphere, so the
  character can look around and roll, with no 3D engine (`C:BotEngine.swift:983-1010, 1113-1146`).
- **Motion comes from one small hand-written engine.** `BotEngine` runs keyframe tweens with four
  easing curves, locks a property while a tween owns it, exponentially smooths every other
  property toward a target, runs a spring for the mouth, and adds a particle system. Emotions do
  not morph: the eye shape is swapped outright, usually hidden inside a blink. Colour and tint
  fade (`C:BotEngine.swift:5-29, 641-781`).
- **There are 11 states and 7 emotes.** States are keyed to Claude Code hook events
  (`C:HookServer.swift:144-228`). Emotes come from pointer play (hover, slap, drag) and app
  outcomes. Three states and two emotes are defined but never triggered on macOS (see the
  state machine below).
- **Two scripted scenes are separate renderers.** The launch greeting and the file-drop "gulp"
  are pure functions of time (`pose(t)`, `frame(t)`). The drop scene runs fixed-step spring
  physics at 240 Hz (`C:GreetingCanvasView.swift`, `C:UploadSequenceEngine.swift`). This is the
  cleverest part of the repository.
- **Licence.** The code is MIT (`C:LICENSE`). The name, the Mochi character ("its design, look,
  expressions and animations as a character"), the icons and all 28 sounds are *all rights
  reserved* (`C:LICENSE-ASSETS.md`). We may learn the techniques. We may not ship Mochi, its look
  or its sounds. ADR 0002 already asks us to work clean-room.
- **Dots.** I could not verify anything about OpenAI "dots" from openai.com: every fetch returned
  a Cloudflare 403 challenge. See the section on Dots near the end. Coucou itself does not
  mention OpenAI. It says it was inspired by "notch-companion concepts shared by design studios"
  (`C:README.md:27, 145`).
- **For us.** Three things are worth taking: the procedural face technique (eyes on a sphere and
  a blink scheduler), the "pose as a pure function of time" way of writing scripted moments, and
  the event-to-emotion table as a design pattern. Their always-running 60 Hz loop is not worth
  taking. Neither is their hover logic, which is weaker than ours. A character in *our* compact
  strip collides with ADR 0003, so it needs a decision first (see the recommendations).

---

## Part 1. The character

### 1.1 Rendering technology

| Piece | How | Where |
|---|---|---|
| Frame clock | `TimelineView(.animation(paused: state.mode == .hidden))`. The main bot is paused while the island is hidden. | `C:BotCanvasView.swift:13` |
| Drawing | SwiftUI `Canvas { context, size in … }` using `GraphicsContext` paths and gradients | `C:BotCanvasView.swift:14-37` |
| dt | `min(0.05, now - engine.lastTime)`, so a stalled frame never jumps more than 50 ms | `C:BotCanvasView.swift:16` |
| Per-frame order | `update(dt)`, then `drawHandsBehind`, then `draw` (body, blush, eyes, mouth), then `drawHandsAndExtras` (badge, particles) | `C:BotCanvasView.swift:34-37` |
| Mini bots | Each pill gets its own `BotEngine` and its own **unpaused** `TimelineView(.animation)` | `C:BotCanvasView.swift:122-161` |
| Greeting | A separate `Canvas` using `withCGContext`, so plain CoreGraphics | `C:GreetingCanvasView.swift:560-566` |
| Upload scene | A separate `Canvas` driven by `UploadSequenceEngine.frame(at:)` | `C:UploadCanvasView.swift:14-22` |
| Halo | A SwiftUI `Circle` filled with a `RadialGradient`, blurred by 6, behind the canvas | `C:IslandRootView.swift:261-277` |

The architecture is JS-first. `C:docs/SPEC.md:112` orders the prototype's `Bot` class "ported as
is" to Swift. Comments throughout say "mirrors prototype". The HTML prototype
(`C:design/prototype/notch-buddy.html`, 86 KB, Canvas 2D plus WebAudio) is the "visual source of
truth" (`C:CLAUDE.md`). The Windows port redraws the same shapes in Canvas 2D (`C:windows/README.md:125`).

### 1.2 Geometry

All sizes are relative to `R = 0.3 × canvas width` (`C:BotEngine.swift:788`). The view gives the
canvas a side of `diameter / 0.6` (`C:IslandRootView.swift:255`). So **R = diameter / 2**.

- **Body.** A superellipse `|x/rx|^2.7 + |y/ry|^2.7 = 1`, with `rx = 1.14R` and `ry = 0.88R`. The
  body is therefore about 1.3 times wider than tall and wider than the nominal diameter. It is
  sampled at 72 steps (`C:BotEngine.swift:983-1010`, where `expN = 2/2.7`). The centre sits
  `0.06R` below the canvas centre (`C:BotEngine.swift:795`).
- **Morph to a box** for the file drop. Each boundary point is lerped toward the matching point
  on a rounded rectangle (1.0R × 0.94R, corner 0.42R). The matching point is found by
  intersecting a ray with the rounded rectangle (`C:BotEngine.swift:986-1051`). The upload scene
  morphs another way: it animates the superellipse *exponent* from 2.15 to 5.5
  (`C:UploadCanvasView.swift:557-573`). That is a cheaper and smoother way to get from a blob to
  a box.
- **Body shading.** Four layers, all clipped to the body path (`C:BotEngine.swift:1053-1099`):
  1. a linear gradient from `#EDEDEF` at top right to `#C4C5CA` at bottom left
     (`C:BotEngine.swift:81-82`);
  2. a state tint: a linear gradient from the bottom, at `0.72 × tint` opacity, fading to clear
     at the top;
  3. a radial "shadow rim": clear to 60%, then 20% black at the edge;
  4. a radial specular highlight: 55% white at `(0.34rx, −0.46ry)`, radius 0.42R.

  Mini bots use a flat brand colour with no shading (`C:BotEngine.swift:1054-1056`).
- **Blush.** Two pink ellipses, 0.34R × 0.2R, colour `rgb(255,120,150)` at `0.5 × blush`. They
  slide sideways with yaw (`sin(yaw)·rx·0.8`). The blush never drops below `tint × 0.5`
  (`C:BotEngine.swift:808-812, 1101-1111`).
- **Eyes on a sphere.** This is the key trick (`C:BotEngine.swift:1113-1146`):
  - each eye sits at yaw `±0.37` rad and pitch `−0.12` rad on an imaginary sphere
    (`C:BotEngine.swift:77-80`);
  - its screen position is `x = sin(yaw)·cos(pitch)·rx`, `y = −sin(pitch)·ry`;
  - it is foreshortened by `max(0.18, cos yaw)` horizontally and `max(0.18, cos pitch)`
    vertically;
  - it is culled when `cos(yaw)·cos(pitch) < 0.04`, meaning it has gone behind the head;
  - `roll` is added to the pitch and wrapped to ±π, so during a roll the eyes leave over the top
    and come back from the bottom. That is the finished and dizzy "roll-through".

  Eyes measure `0.25R × 0.27R`. Mini bots draw them 1.9 times larger so they stay legible at
  12–22 pt (`C:BotEngine.swift:1137-1139`). Ink is `#1A1412`, or `#10131A` on minis
  (`C:BotEngine.swift:83-84`).
- **Hands.** Two ellipses of `0.30ry × 0.26ry`, scaled by `hands` from 0 to 1, drawn behind the
  body. They are drawn only when `R > 14` pt, never in the compact strip. While waving, the right
  hand rises in 180 ms and then circles at 13 rad/s, about 2.1 Hz (`C:BotEngine.swift:867-961`).
- **Mouth.** It appears only in box mode: a dark gradient pill whose height is the spring
  `slotH`, with a 1-pt white rim at the top and a lip line at the bottom
  (`C:BotEngine.swift:817-859`).
- **Badge.** It sits top-left at `(−0.72R, −0.72R)` and comes in four kinds: a pill with three
  pulsing dots at 2.4 Hz (with a phase offset per dot), a "!", a "?", or a coloured dot
  (`C:BotEngine.swift:1258-1317`).

**Sizes on screen.** The view layouts are in `C:IslandTypes.swift:89-110`, and the position
function is `botPosition` (`C:IslandRootView.swift:341-367`).

| Where | Diameter (pt) | R | Notes |
|---|---|---|---|
| hidden | 6 | 3 | opacity 0 |
| compact strip | **20** | 10 | at (40, 16) in the island. That is on the left "ear", which is `nw + 160` wide, beside the camera housing and not under it (`C:IslandWindowController.swift:854`) |
| compact mini grid | 12 | 6 | a 2×2 grid right of the notch (`C:IslandRootView.swift:538-556`) |
| overview / empty | 58 / 62 | 29 / 31 | the expanded island is 640 pt wide and 160 pt tall |
| alerts | 56–58 | | |
| confused (dizzy) | 66 | | |
| chat / result | 44 | | |
| pills / column minis | 22 / 16 | | |
| drag ghost | about 40, in its own panel | | `C:IslandWindowController.swift:481-521` |

**Fit to the notch.** The island is a black `IslandShape`: square top, rounded bottom (14 pt
compact, 22 pt expanded). The shape can also cut concave "ears" (`C:IslandRootView.swift:172-244`),
though `topRadius` is always set to 0 in practice (`C:IslandRootView.swift:120, 154`). The real
notch size is read from `NSScreen.auxiliaryTopLeftArea/RightArea` and `safeAreaInsets.top`
(`C:IslandWindowController.swift:756-770`), which is the same approach as our `NotchGeometry`.

### 1.3 Colours per state

Taken from `C:BotEngine.swift:89-166`. The halo colour comes separately from
`C:IslandRootView.swift:319-338`.

| State | Body tint colour | Tint | Eyes | Badge | Motion flags |
|---|---|---|---|---|---|
| idle | `#E6E9EE` | 0 | pill | none | none |
| working | `#3B9EFF` | 0.72 | pill | dots | none |
| thinking | `#8B5CF6` | 0.72 | pill | dots | fixed look up-right (0.55, 0.55) |
| searching | `#6366F1` | 0.72 | pill | dots | `scans`: eyes sweep `sin(2.6t)·0.6` |
| approval | `#F5A524` | 0.78 | wide (×1.16/×1.12) | `!` | `bounces`: `−|sin(5.2t)|·0.07R` |
| question | `#22D3EE` | 0.75 | pill | `?` | head tilt 0.17 rad |
| error | `#F4505E` | 0.78 | flat | dot | none |
| finished | `#34D399` | 0.35 | happy arc | dot | none |
| ratelimit | `#FB923C` | 0.72 | tired (lid over pill) | dot | `sweat` particles |
| sleeping | `#94A3B8` | 0.32 | closed arc | none | `breathes`, `zz` |
| dizzy | `#F472B6` | 0.70 | spiral (spins at 9 rad/s) | none | look wobble `sin(9t)·0.25` |

Each state also carries `sound:`, but that field is never read. Sounds are played by the callers
instead (a grep for `cfg.sound` finds nothing; see section 1.8).

### 1.4 States: the full state machine

`effectiveState = stateOverride ?? focusTask?.state ?? .idle` (`C:AppState.swift:219-221`). The
big Mochi shows the *focused* task. The other tasks appear as mini bots. When the focused task is
an integration pill, the big bot also turns flat brand colour (`C:BotCanvasView.swift:31-33`). A
change of `effectiveState` calls `engine.setState` (`C:BotCanvasView.swift:40-42`).

**Triggers.** Claude Code events arrive through a Unix-socket hook
(`C:HookServer.swift:144-228, 257-339`). **Only events from VS Code are accepted**; everything
else is ignored (`C:HookServer.swift:133-140`).

| State | Set by | Cleared by | One-off action on entry (`setState`) |
|---|---|---|---|
| idle | default; `SessionEnd` (`:215-218`); 5.2 s after `Stop` (`:201-204`) | any event | a blink, unless coming from idle |
| thinking | `UserPromptSubmit` (`:153-160`); sending a chat message sets override `.thinking` (`C:IslandViewContent.swift:795`) | next event, or a chat reply (`C:ClaudeService.swift:272`) | blink |
| working | `PreToolUse`, `PostToolUse`, `PostToolUseFailure` (`:162-177`); after an approval decision (`:336`) | next event | blink |
| approval | `PermissionRequest` (`:295`). This also pins the island, forces it open, and answers "ask" automatically after 115 s (`:297-309`) | Allow/Deny click, which goes to working | jump: `oy` to −0.2R in 150 ms (out), back in 300 ms (back) (`C:BotEngine.swift:281-285`) |
| question | `Notification` whose message ends in `?` (`:185-187`) | next event | blink |
| ratelimit | `Notification` containing "rate limit" or "limite d" (`:182-184`) | next event | one sweat drop |
| finished | `Stop` (`:190-204`); the n8n, Vercel and Stripe pollers set it on their minis (`C:N8nPoller.swift:238`, `C:VercelPoller.swift:88`, `C:StripePoller.swift:139`) | back to idle after 5.2 s | a full roll in 950 ms (`inOut`), plus 5 sparks 0.5 s later (`C:BotEngine.swift:269-273`) |
| error | `StopFailure` (`:206-213`); a chat or API failure sets override `.error` (`C:ClaudeService.swift:329`); pollers | next event | head shake `ox`: +0.08 / −0.08 / +0.05 / 0 in 50/70/70/90 ms (`C:BotEngine.swift:274-280`) |
| dizzy | three slaps within 1.7 s (`C:BotEngine.swift:361-371`), which set override `.dizzy` and the view `confused` (`C:IslandWindowController.swift:705-721`) | 3.3 s timer, then the `happy` emote | a double roll in 1300 ms |
| searching | **never set on macOS.** Defined only (a grep finds no writer) | — | — |
| sleeping | **never set on macOS.** The spec wanted it after 10 minutes with no task (`C:docs/SPEC.md:140`) | — | — |

**Emotes** are temporary eye overrides, 1.8 s by default, plus motion
(`C:BotEngine.swift:550-619`):

| Emote | Eyes | Motion | Real trigger |
|---|---|---|---|
| love | heart `#FF4D6D` | blush to 1, 4 hearts, a small hop | pointer resting on Mochi 1.9 s, cooldown 6 s (`C:IslandWindowController.swift:272-298`); drag start (`:407`) |
| happy | arcs | blush 0.6, then 0 | window attached (`:426`), recovery from dizzy (`:717`), file dropped or uploaded (`C:FileDropView.swift:78,111`), chat reply (`C:ClaudeService.swift:274`) |
| proud | rotating stars `#F7B32B` | 5 stars, tilt −0.14, blush 0.7 | a structured Claude result (`C:ClaudeService.swift:325`) |
| wink | left pill, right arc | tilt 0.12 | email sent (`C:IslandViewContent.swift:702`) |
| annoyed | slanted lines | none; the squash comes from `slap` | slaps 1 and 2 (`C:BotEngine.swift:372-378`, set directly, not through `triggerEmote`) |
| surprised | dots | hop −0.3R, eye scale 1.25 | **never triggered.** The spec wanted it on grab (`C:docs/SPEC.md:147`); the code shows `love` there instead |
| yawn | tired, then closed | stretch sy 1.12 over 1 s, 2 z's | **never triggered** |

Other dead or unfinished pieces, which suggest the macOS port is younger than the spec:
- `BotEngine.greet()` is complete, but nothing posts `.botGreet`, so it never runs. The launch
  greeting is `GreetingCanvasView` instead.
- `AgentTask.emote` and `miniEye` are never set, so `setPermanentEmote` and the mini "periodic
  behaviours" (happy hop, annoyed shake, wink, love) never fire (`C:BotEngine.swift:384-453`).
- `absenceInterval` and `greetThresholdSeconds` are saved but never read (`C:AppState.swift:98-106`).
- The `silent:` parameter of `triggerEmote` is unused.

**Pointer interaction** is polled at 60 Hz (`C:IslandWindowController.swift:194-266`):
- **Hover over the bot** (expanded only, no override active): blink, eye scale target 1.08, sound
  `hover`. After 1.9 s still, `love` fires. Moving more than 40 pt restarts the 1.9 s timer
  (`:246-259`).
- **Click on the bot** (expanded): a slap, which is a squash of `sy` 0.78/1.1/1 and `sx`
  1.16/0.95/1 over 70/130/170 ms, then `annoyed` for 0.8 s, with sounds `slap` and, 60 ms later,
  `annoyed` (`C:BotEngine.swift:321-332, 361-380`).
- **Drag the bot more than 3 pt:** a ghost Mochi in its own panel follows the cursor. It scales in
  with spring(0.28, 0.55) and fades in over 180 ms. A white highlight frame follows the window
  under the cursor. Dropping it there captures that window as chat context (`:400-451, 481-626`).
  The capture uses `CGWindowListCopyWindowInfo` and is excluded from the App Store build.

**The island FSM**, separate from Mochi (`C:IslandStateMachine.swift`), has four states: hidden,
petit (compact), home (expanded) and coucou (the greeting). Home returns to petit after 15 s
without the pointer. Petit goes to hidden after 60 s. After the greeting it collapses 0.6 s later,
or 10 s later if the pointer is over it (`:20-27`). Launch always plays the greeting
(`C:AppDelegate.swift:65`). A non-alert hook event reveals the compact strip. An alert forces the
island open (`C:HookServer.swift:233-252`).

### 1.5 Animation mechanics

**Easing.** Four curves (`C:BotEngine.swift:7-12`):
- `out`: cubic, `1−(1−t)³`
- `inOut`: cubic
- `back`: overshoot with c1 = 1.7
- `lin`: linear

**Tweens.** A tween is `TweenKey(target, duration_ms, ease)` chained as keyframes on a named
property. While a tween runs, its property is *locked* against the smoothing below. It unlocks on
the last key, and can run an `onComplete` (`C:BotEngine.swift:645-668, 1357-1363`). Fifteen
properties are animatable: yaw, pitch, roll, tilt, open, sx, sy, oy, ox, tint, morph, hands,
blush, es, badgeS (`C:BotEngine.swift:1374-1393`). Starting a new tween on a property takes over
from its current value, so interruptions never jump.

**Continuous smoothing** (`C:BotEngine.swift:730-742`). Unlocked properties move toward their
targets as `x += (target − x)·(1 − b^dt)`, which is frame-rate independent:

| Base b | Properties | Time constant |
|---|---|---|
| 0.0025 | look (yaw, pitch) | about 0.17 s (τ = −1/ln b) |
| 0.0008 | tilt, sx, sy, es, the bounce `oy` | about 0.14 s |
| 0.002 | the body colour | about 0.16 s |

`tint` itself is not smoothed. `setTarget("tint")` assigns it at once
(`C:BotEngine.swift:1368`, despite the comment there), so the tint strength jumps while its hue
fades.

**Look and cursor-follow.** The pointer's screen position is polled at 60 Hz
(`C:IslandWindowController.swift:224-230`). Then:
- `lookX = tanh((mouseX − botScreenX)/260)` and `lookY = −tanh((mouseY − botY)/200)`
  (`C:BotCanvasView.swift:93-118`);
- the yaw target is `lookX·0.62` and the pitch target is `lookY·0.5`
  (`C:BotEngine.swift:672-673`).

The eyes follow the pointer *anywhere on screen*, including in compact mode. Overrides:
- a state with a fixed look blends 35% pointer with 55% the fixed direction;
- `scans` replaces the look with a sine sweep;
- sleeping looks down at −0.14;
- dizzy wobbles (`C:BotEngine.swift:675-684`);
- mini bots ignore the pointer and wander, picking a random target every 0.5–2 s
  (`C:BotEngine.swift:686-697`).

**Blink** (`C:BotEngine.swift:313-319, 744-753`). `open` goes to 0.06 in 70 ms (`inOut`), then
back to 1 in 130 ms (`out`). The next blink is scheduled 2.2 + U(0, 3.2) s later, so every 2.2 to
5.4 s. A second blink follows 230 ms later 22% of the time. There is no blink while sleeping or
dizzy. The pill eye's height is `max(h·open, w·0.3)`, so a closed pill is still a slit
(`C:BotEngine.swift:1157`).

**Idle life.**
- The big bot has no idle breathing unless its state `breathes`: then `sy = 1 + sin(1.8t)·0.035`,
  `sx = 1 − sin(1.8t)·0.02`. Its idle life is blinks plus pointer-following.
- Mini bots pulse all the time (`sy = 1 + sin(2.2t)·0.04`), each with its own random phase
  `t0` (`C:BotEngine.swift:242, 713-723`).

**Springs.**
- *Mouth:* a hand-integrated damped spring with ω₀ = 2π/0.25 ≈ 25 rad/s and ζ = 0.6
  (`C:BotEngine.swift:772-778`). Its targets are 0.20R when a file hovers over the box, 0.42R
  while gulping and 0 otherwise (`C:BotCanvasView.swift:23-28`, `C:BotEngine.swift:336-345`).
- *Upload scene:* spring(response, damping) with `k = (2π/response)²` and `c = 2ζ√k`, stepped at a
  **fixed 1/240 s** until it catches up with the wall clock (`C:UploadSequenceEngine.swift:84-93,
  246-252`). The box follows the cursor with (0.35, 0.70) and snaps to it more tightly with
  (0.18, 0.75) once "locked": within 60 pt and slower than 180 pt/s, released beyond 90 pt
  (`:258-272`). The box tilts with its own horizontal velocity, clamped to ±0.18 rad (`:275-276`).
- *SwiftUI side:* island open spring(0.5, 0.72); close `timingCurve(0.45, 0, 0.2, 1)` over 0.34 s
  (`C:IslandRootView.swift:32-33`, `C:IslandWindowController.swift:317-320`). Bot position and
  size spring(0.5, 0.72) (`C:IslandRootView.swift:305-307`). View content spring(0.4, 0.8)
  delayed 0.16 s on the way in, easeIn 0.16 s on the way out (`C:IslandRootView.swift:431-433`).
  Halo colour easeInOut 0.4 s.

**Particles** (`C:BotEngine.swift:621-637, 761-770, 1319-1353`):
- five types: heart, star, spark, sweat, z;
- each lives 1.3 to 1.8 s, with a staggered start of 140 ms per particle;
- each rises at 0.45 to 0.8 R/s, fades in over its first 20% and out over the rest, and grows by
  40%;
- hearts wobble with `sin(6·age)·0.3`;
- ambient z's and sweat are emitted every 1.3 s;
- the canvas is given a 40-pt "overhang" above the bot so hearts can rise without clipping
  (`C:IslandRootView.swift:256, 301-304`).

**Transitions between emotions.** There is no shape morphing between expressions. An eye shape is
an enum drawn by a `switch` (`C:BotEngine.swift:1148-1256`). Changing expression swaps the shape
at once. What makes it feel smooth: `setState` blinks on most changes, so the swap happens while
the eyes are shut; body colour and halo fade; the badge scales down in 90 ms, is swapped, and
scales back up in 280 ms with `back` (`C:BotEngine.swift:297-311`); overrides expire back to the
permanent eye (`C:BotEngine.swift:755-759`).

**Scripted scenes as pure functions of time.**
- *Greeting* (`C:GreetingCanvasView.swift`). `greetPose(t)` returns a full pose from `t` alone
  (`:104-180`). Its timeline, in seconds (`:5-26`):
  - grow with `back` easing, 0.02–0.45;
  - happy squint, 0.60–0.82;
  - dip, 1.25–1.40;
  - hands pop, 1.36–1.52;
  - wave, 1.52–2.58;
  - hands tuck, 2.58–2.80;
  - badge, 2.72;
  - settle, 2.85–3.20;
  - second blink, 3.80;
  - blue tint, 3.85–4.15;
  - end, 4.60.

  Leaving is a second function that lerps from the pose at the moment of interruption `tc` to the
  small compact pose over 0.34 s (`:199-226`). An interrupted greeting therefore collapses
  cleanly from wherever it was. The scene also has 5 expanding rings of 170 seeded dots and 16
  coloured streaks, from a fixed-seed linear congruential generator (seed 7) so it looks the same
  every launch (`:83-100`), plus a golden-to-blue halo. Sounds are timed to the script: `greet` at
  1.36 s and `blip` at 2.72 s (`:600-610`).
- *Drop and gulp* (`C:UploadSequenceEngine.swift`, `C:UploadCanvasView.swift`). `frame(t)`
  returns morph, position, squeeze, mouth, eyes, look and the alphas of every part of the scene
  (`:295-436`). Its timeline:
  - drop at 1.95;
  - suck 2.03–2.33;
  - mouth closes by 2.42;
  - chew 2.60–2.88, a 0.14-s squash loop;
  - shrink into a 14-pt dot 2.88–3.23;
  - progress 3.25 to 3.25 + 2.4 s;
  - grow back to the choice view.

  The dropped file's icon is sliced into 28 strips, and each strip is narrowed and clipped as it
  is "sucked" into the mouth (`C:UploadCanvasView.swift:415-472`). **The progress is not real.**
  Its duration is a constant 2.4 s (`C:FileDropView.swift:58`), and a `tick` sound plays every
  10% (`:84-97`).

### 1.6 Performance and energy

What they do:
- The main canvas pauses while the island is hidden (`C:BotCanvasView.swift:13`).
- A dt clamp of 50 ms.
- Pollers are said to pause "when nothing is watching" (`C:README.md`). Not checked in each
  poller.

What they don't do, all read in code:
- **A 60 Hz `Timer` runs for the whole life of the app**, hidden or not. It reads the pointer,
  hit-tests and toggles `ignoresMouseEvents` (`C:IslandWindowController.swift:194-200`). That
  contradicts their own rule "0% CPU when the island is hidden" (`C:CLAUDE.md`).
- A 10 Hz countdown `Timer` also always runs (`C:IslandRootView.swift:389-393`).
- `MiniBotCanvasView` timelines never pause. In compact mode up to four minis draw at display
  rate, each with its own engine (`C:BotCanvasView.swift:137`, `C:IslandRootView.swift:538-556`).
  In expanded mode, pills and the column add more.
- The body path is rebuilt every frame: 73 `pow` pairs, plus gradients.
- There is no `accessibilityReduceMotion`, no occlusion check, and no pause for fullscreen or a
  locked screen (a grep finds none).

How much this costs is not measured here. **Uncertain:** on ProMotion displays
`TimelineView(.animation)` may run at up to 120 Hz.

### 1.7 Assets and customisation

- No image assets for the character at all. Everything is procedural.
- The only character setting is sound: on or off, and volume 0–0.2, default 0.12
  (`C:SettingsView.swift:224-232`, `C:AppState.swift:71-82`), plus a speaker toggle in the island
  header (`C:IslandRootView.swift:489-494`).
- No choice of character, colour or size, and no switch for motion or the greeting.
- The prototype explored **three character "tracks"** (`C:design/prototype/notch-buddy.html:518-522`),
  which is a useful design record:
  - *Galet*: a matte pebble circle with tall pill eyes, "very legible when tiny";
  - *Mochi*: the chosen one;
  - *Lueur*: an orb that takes its state colour, "you know what is happening without reading,
    even from afar".
- The Swift Mochi is cooler grey (`#EDEDEF→#C4C5CA`) than the spec and prototype's warm
  `#FFFAF5→#DDCCBF` (`C:docs/SPEC.md:115`). This is a divergence, and it is uncertain whether it
  was deliberate.

### 1.8 Sound and haptics

- There are **28 WAV files**: 48 kHz, 16-bit stereo, 3.0 MB in all (checked with `afinfo`). The
  spec says they were "rendered from the prototype's engine with a gain of ×6"
  (`C:docs/SPEC.md:166`). That engine synthesises every sound in WebAudio: pitched tones with
  glides, vibrato and harmonics, plus filtered noise (`C:design/prototype/notch-buddy.html:484-515`).
  For example, `greet` is a C-E-G arpeggio 85 ms apart and `slap` is a 280→110 Hz triangle plus
  noise.
- Playback: `SoundEngine` preloads a **pool of 3 `AVAudioPlayer` per sound** so sounds can
  overlap, and picks the first one that is not playing (`C:SoundEngine.swift:15-49`).
- Which event plays which sound:
  - `peek`: hidden → compact;
  - `open` / `close`: the island;
  - `hover`, `love`, `slap`, `annoyed`: pointer play;
  - `work`: `SessionStart`;
  - `approval`, `finish`, `error`, `rate`: hook events;
  - `blip`: pill focus;
  - `approve` and `tick`: the drop;
  - `send`: email;
  - `greet` and `blip`: the greeting script.
- **No haptics** (a grep finds none).
- The sounds are *all rights reserved* (`C:LICENSE-ASSETS.md`).

---

## Part 2. The rest of the repository, judged for Capacity Notch

| Area | What Coucou does | Useful to us? |
|---|---|---|
| Panel | An `NSPanel` of fixed size 720×320, borderless and non-activating, at level mainMenu+3, with `[.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]` and `constrainFrameRect` overridden (`C:IslandWindowController.swift:51-77, 779-789`) | Ours is equivalent or better. We use mainMenu+1 and the same behaviours (`CN:Sources/CapacityNotch/NotchPanelController.swift:709-718`), and a fixed window with spring overshoot room (`:1085-1105`). **Nothing to take.** |
| Click-through | Toggles `ignoresMouseEvents` every frame against the island rectangle, inset by −6 | Same idea as ours at 10 Hz (`CN:…/NotchPanelController.swift:769-775`). **Ours is cheaper.** |
| Hover | Opens on hover immediately. The FSM uses timers of 15 s and 60 s | Ours has intent filtering (3 ticks, 0.3 s), a leave grace, and a nearing "give" (`CN:…/NotchPanelController.swift:35-41, 812-852`). **Ours is better.** |
| Multi-display | The notch screen is chosen once at launch. No screen-change observer | We follow `didChangeScreenParametersNotification` and a preferred display (`CN:…/NotchPanelController.swift:141-144, 730-741`). **Ours is better.** |
| Fullscreen | Not handled; it just joins as auxiliary | We detect fullscreen and adapt (`CN:Sources/CapacityNotchCore/FullscreenDetection.swift`). **Ours is better.** |
| Screen sharing | Not handled | We have `sharingType` control and teleprompter exclusion. **Ours is better.** |
| File drop | A sibling `NSView` drag destination over the hosting view, whose `hitTest` returns nil (`C:IslandWindowController.swift:85-131`) | We solved the same thing with `SurfaceDropView` as the container. Nothing to take, but their **drop choreography** (the file sucked into a character's mouth) is a nice idea for our Shelf. |
| Drag-to-attach a window | `CGWindowListCopyWindowInfo` under the cursor, then a highlight panel | Their use is chat context, which we don't have. A **drag the character onto a window** gesture could someday target the Shelf or Dictation. Low priority. |
| Claude Code hooks | The `nb-hook` script talks over a Unix socket to the app. PermissionRequest is held open until the user decides, then "ask" after 115 s. Only VS Code | We read Capacity only (ADR 0001) and have no hooks. A hook bridge would be a large scope change. **Not recommended now.** |
| Integrations | Stripe, n8n, GitHub, Vercel, Resend, Notion and Cal.com pollers, with keys in the Keychain | Outside our scope. |
| Sound | Pooled `AVAudioPlayer` | A good pattern if we ever add sounds. It would need our own sounds. |
| Packaging | XcodeGen `project.yml`, an App Store variant (`#if APPSTORE`), and `scripts/release.sh` | We use SwiftPM. Nothing to take. |
| Spec discipline | A French SPEC, a prototype as the visual truth, and `design/captures/*` as target screenshots | We already have drawings and `docs/`. Keeping **target captures of every character state** would be worth copying if we build one. |

---

## Part 3. Comparison with Capacity Notch, and where a character could go

### 3.1 How our surface moves today

- **One surface, two presentations.** `CapacityNotchStore.Presentation` is either compact or
  expanded, with a pin (`CN:Sources/CapacityNotchCore/CapacityNotchStore.swift:4-81`).
  Coucou has four island modes plus 17 views.
- **The shape moves, not the window.** `NotchOutline` is animated with
  `SurfaceType.surfaceMotion`: open is spring(0.42, 0.8), close is spring(0.45, 1.0), and
  reduce-motion gets easeInOut 0.15 (`CN:Sources/CapacityNotch/NotchRootView.swift:53-58`).
  Content moves with `contentMotion` (`:64-69`). Reduce motion is honoured throughout (`:266, 412`).
  Coucou has none of this.
- **Redraw rate.** Our surface redraws on a **30-second** `TimelineView(.periodic)`
  (`CN:…/NotchRootView.swift:154`) and on published changes. The pointer is polled at 10 Hz.
  With nothing happening we draw almost nothing. Coucou draws its minis continuously. A character
  would be the first thing on our surface that wants a per-frame clock.
- **We already have one "presence".** The Dictation Capsule renders the vendored Murmur Metal orb
  (MIT, `CN:Vendor/Murmur/README.md`). It maps our dictation phases onto Murmur states:
  hidden→idle, recording→listening, recognizing→thinking, inserted/copied→success, error→error.
  It passes the live microphone level as a signal, recolours by outcome, and uses
  `animated: !reduced` (`CN:Sources/CapacityNotch/DictationPanel.swift:60-101`). Murmur runs at a
  configurable `fps`, default 30 (`CN:Vendor/Murmur/Sources/Murmur/MurmurView.swift:55, 77`).
  **This is our existing, working precedent** for a state-driven animated presence. It is a glass
  orb, not a face.

### 3.2 The constraint that decides placement: ADR 0003

- "The compact strip is still Capacity's … a Module may add a row *beneath* Capacity, never
  replace it" (`CN:docs/adr/0003-capacity-notch-hosts-built-in-modules.md`, amended 2026-09-24).
- Our compact strip is already full. It holds one Provider figure on each side of the physical
  notch, with the notch itself as the gap (`CN:…/NotchRootView.swift:422-452`).
- The strip widths, 370 and 410 pt, are the author's drawings (`CN:Sources/CapacityNotchCore/NotchGeometry.swift:51-64`).
- Coucou puts a 20-pt Mochi on the left ear of a strip 160 pt wider than the notch. Copying that
  would mean either widening our strip or giving up a Provider figure. Both need an ADR decision.
- Every non-Capacity Module is off until asked for, and runs nothing while off (ADR 0003). A
  character would be the same.
- Anything drawn *under* the camera housing is invisible. Coucou avoids that, and so must we.

### 3.3 Events we already have that could drive emotions

These are listed in our vocabulary. Each row names a signal that already exists in code.

| Our signal | Where | Possible emotion |
|---|---|---|
| Capacity Pace of the shown Quota Window (sustainable / tightening / unsustainable) | `CN:Sources/CapacityNotchCore/CapacityPace.swift:7-100` | calm, then attentive, then tired or sweating. This is the natural "mood" of the Capacity Module |
| A Capacity Alert decided | `CN:Sources/CapacityNotchCore/CapacityAlerts.swift:46`, `CN:Sources/CapacityNotch/AppDelegate.swift:717` | alarmed, a one-off |
| Fresh vs Stale Capacity, and connection state (connecting, fresh, stale, disconnected with a reason) | `CN:Sources/CapacityNotchCore/CapacitySnapshot.swift:158-165` | stale: sleepy or unsure; disconnected: confused; connecting: "thinking" |
| A Quota Window reset (remaining jumps up) | **not an event today.** It would have to be derived by comparing snapshots (uncertain design) | relief or joy |
| Dictation presentation: recording, recognizing, inserted, copied, error | `CN:Sources/CapacityNotch/DictationController.swift:9-11` | listening (ears or mouth follow the microphone level), thinking, happy, puzzled, sad |
| Shelf: a file held over the strip (`isDropTargeted`), then added | `CN:Sources/CapacityNotch/ShelfController.swift:19`, `CN:…/NotchPanelController.swift:96-106` | eager, with the mouth opening (their gulp idea), then content |
| Teleprompter running, paused or finished | `CN:Sources/CapacityNotchCore/Teleprompter/TeleprompterPlayback.swift:14-19` | **stay still or hide.** Nothing should move near the camera while a person reads |
| Music playing | `CN:Sources/CapacityNotch/MusicReader.swift:17-20` | a gentle sway. We have no beat data (uncertain value) |
| Pointer near, over, or opening the surface | `CN:…/NotchPanelController.swift:812-852` | looks at the pointer, blinks on open |
| Fullscreen on the chosen display | `CN:Sources/CapacityNotch/SurfaceMetrics.swift:15, 92-98` | asleep or hidden |

### 3.4 Prioritised ideas

Effort figures are rough, for one person, and include tests of the pure parts in
`CapacityNotchTests`.

1. **Decide first, then draw.** Effort: 0.5–1 day. Risk: low.
   - Write an ADR (ADR 0006?) on whether the character belongs to the Capacity Module or is its
     own Module, and where it may appear given ADR 0003. Candidate places:
     - (a) the expanded surface only;
     - (b) the Dictation Capsule;
     - (c) a widened compact strip.
   - Record that Mochi's look, name and sounds are off-limits (`C:LICENSE-ASSETS.md`), and that
     only techniques are taken, per ADR 0002.
   - Add a glossary term with `/domain-modeling`. "Companion" or "Mascot" are candidates; the name
     is the author's choice.
2. **A pure "Mood" model in `CapacityNotchCore`.** Effort: 1 day. Risk: low.
   - Map the signals in 3.3 to a small enum of moods, plus one-off "reactions" that expire.
   - Use Coucou's split: permanent state, plus a temporary override with an expiry that falls
     back to the permanent one (`C:BotEngine.swift:217-222, 755-759`).
   - Leave out their NotificationCenter fan-out (8 notification names). Use one published value.
3. **A procedural face renderer.** Effort: 2–4 days. Risk: medium (CPU, taste).
   - Draw with `Canvas`, ideally a 2–3 line eye language: pill, arc, line. Coucou shows that at
     12–20 pt only eyes read, which is why its minis draw them 1.9 times larger.
   - Adapt the eye-on-sphere projection (a few lines, with attribution if code is adapted, per
     ADR 0002), the random blink (2.2–5.4 s, 22% doubles) and the `1−b^dt` smoothing. These give
     most of the "alive" feeling for very little code.
   - Swap expressions inside a blink instead of morphing.
   - Energy rules we must add, where Coucou falls short:
     - animate only while something is changing, and pause the timeline between blinks, for
       example by scheduling the next blink with a timer and running `TimelineView(.animation(paused:))`
       only for about 300 ms around it;
     - stop for reduce motion (show a static face), occlusion, fullscreen, a locked screen and a
       running teleprompter;
     - cap at 30 fps as Murmur does.
4. **The Dictation Capsule as the first home.** Effort: 1–2 days. Risk: low to medium.
   - It is already a temporary, state-driven presence with a live level signal, outside the
     strip, so it needs no change to ADR 0003.
   - Either a face variant beside Murmur, or eyes drawn over the orb.
   - This is where "emotion" is most legible: listening, thinking, done, failed.
5. **A mood in the expanded surface.** Effort: about 1 day. Risk: low.
   - A small face in the Capacity page header that reflects the worst Capacity Pace and
     staleness.
   - It stays at rest when nothing changes.
6. **Scripted moments as pure `pose(t)` functions.** Effort: 1 day each. Risk: low.
   - A Capacity Alert, a Quota Window reset, a file landing on the Shelf (a small "gulp"), first
     launch.
   - Coucou's pattern (`C:GreetingCanvasView.swift:104-226`) makes them testable, since a pose at
     time *t* is plain data, and makes them interruptible, since the collapse lerps from the pose
     at `tc`.
7. **Pointer play.** Effort: 0.5–1 day. Risk: medium (annoyance).
   - Eyes following the pointer while the surface is open.
   - Perhaps love on resting, with Coucou's 6-s cooldown. Skip the slap and dizzy, which is a toy.
8. **Sound.** Effort: 1–2 days plus sound design. Risk: medium.
   - Only if the author wants it: off by default, our own sounds, a pooled player.
   - Keep it silent for routine Capacity refreshes. Coucou's own spec says silent updates get no
     sound (`C:docs/SPEC.md:182`).

**What not to take:**
- the always-on 60 Hz loop;
- a separate TimelineView per mini character;
- string-keyed tween properties (`"yaw"`, `"sy"`), which are type-unsafe;
- NotificationCenter as the character's API;
- the fake progress bar;
- VS Code-only hook parsing.

**Risks to watch:**
- licensing (the character design is protected, not only the code);
- a steady CPU or GPU cost on a surface that is always visible;
- distraction near the camera during calls and teleprompter use;
- screen sharing: the character must follow the surface's `sharingType`;
- VoiceOver: expressions need spoken equivalents, as `CapacitySpeech` gives the figures;
- widening the strip changes the author's drawings.

---

## Part 4. OpenAI "dots": what could and could not be verified

- `https://openai.com/index/introducing-dots/` and
  `https://help.openai.com/en/articles/20001530-getting-started-with-your-dot` both answered
  **HTTP 403** to WebFetch and to curl, behind a Cloudflare challenge page. I did not try to get
  past it. **Nothing on those pages was read directly.**
- A web search restricted to openai.com returned only search-engine summaries of those pages.
  Those summaries say:
  - dots are "always-on agents in ChatGPT" that keep working between conversations;
  - a dot's avatar can be chosen from "characters" or a "pet";
  - they are rolling out to Pro, Business Premium and Enterprise plans.

  These are secondhand, not quotations I could check, so treat them as **unverified**.
- **Not verified at all:** that dots have emotional expressions, that they appear in a Mac notch
  or the menu bar, or what they look like or how they animate.
- Coucou's primary sources never mention OpenAI or dots. They credit design-studio
  "notch-companion concepts" (`C:README.md:27, 145`). The repository was created on 2026-09-27
  (GitHub API). The link to Dots is **the user's hypothesis, not supported by coucou's own
  text**.

## Sources

- Coucou repository at `835421c`: https://github.com/Louis-CFM/coucou/tree/835421c7fff260f0f0be48927591b96bfad81cad
  - licences: `LICENSE` (MIT) and `LICENSE-ASSETS.md`
  - repository metadata via `gh api repos/Louis-CFM/coucou` (created 2026-09-27, MIT, about
    1.16k stars on 2026-10-01); one release, v0.1.0
- OpenAI (fetch refused, search index only): https://openai.com/index/introducing-dots/,
  https://help.openai.com/en/articles/20001530-getting-started-with-your-dot
- Murmur (vendored, MIT): `Vendor/Murmur/README.md`, `THIRD_PARTY_NOTICES.md`
