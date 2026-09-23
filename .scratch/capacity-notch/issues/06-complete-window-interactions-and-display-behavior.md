# 06: Complete window interactions and display behavior

**What to build:** Make Capacity Notch behave like a dependable macOS surface: it appears on exactly one selected display, opens intentionally, can be pinned, and stays available across Spaces and fullscreen applications without leaking its contents into screen capture.

**Blocked by:** 01/Create the clean-room Capacity Notch shell.

**Status:** resolved

- [x] Hover opens a preview only after a short dwell, click pins it open, and repeated click, `Esc`, or click outside closes it predictably.
- [x] The surface works across Spaces and fullscreen applications while remaining on exactly one selected display.
- [x] The built-in display is selected by default, and the user can select one other connected display without enabling simultaneous copies.
- [x] `Hide for 1 hour` removes the surface temporarily and restores it automatically or through the menu bar.
- [x] Capacity contents are excluded from supported screen recording and sharing paths, with a documented fallback where macOS cannot guarantee exclusion.
- [x] Disconnecting, reconnecting, or rearranging displays does not strand the panel off-screen.

## Done

### Opening on purpose

A pointer crossing the strip on its way somewhere else has not asked for
anything, so the surface waits three tenths of a second before opening, and two
tenths after the pointer leaves before closing. A click pins it: it then stays
until it is dismissed, and a pointer wandering off no longer closes it. A second
click, Escape, or a click anywhere else dismisses it.

Escape and the click elsewhere both need the panel to be the key window, which
a borderless panel is not by default. Pinning makes it key and dismissing gives
that up, so the two arrive together and neither works when the surface was only
hovered.

### One display, chosen again each time the displays change

The built-in display holds the surface by default, and one other connected
display can be chosen from **Show On**. The choice is remembered, but it is
resolved against what is actually connected every time: a preferred display
that has been unplugged gives way rather than stranding the surface where
nobody can see it.

`SurfaceMetrics` replaces the geometry that was measured once at launch. A
display arriving, leaving, or changing resolution re-measures the strip and
moves the surface, so a 38-point notch height does not follow the surface onto
a 22-point menu bar.

The collection behaviour keeps one surface across every Space and over
fullscreen applications, and never a second copy elsewhere.

### Hiding

**Hide for 1 Hour** puts the surface away and brings it back on its own; the
menu says how long is left. Providers keep being read while it is away, so it
returns with current Capacity rather than an hour-old reading.

### Screen sharing

The surface is excluded from screen capture and sharing by default
(`sharingType = .none`). Capacity is the person's account standing and a shared
screen is the easiest way to show it to a room by accident.

**The documented fallback:** macOS can exclude a window from the capture paths
it controls. It can promise nothing about a camera pointed at the screen, nor
about capture performed with elevated privileges outside those paths. This is a
strong default, not a guarantee, and **Show In Screen Sharing** turns it off for
anyone who wants the surface in a recording.

## Verified

58 checks pass and `swift build` is clean. Four are new and cover the parts
worth pinning down: the built-in default and that some display is always
chosen, an unplugged preference giving way, the hour elapsing and what the menu
says while it runs, and pinning — that a click holds the surface, that a second
click and a dismissal both let it go.

The running application sits at 560×38 on the built-in display with screen
sharing off.

## Not done

The pointer dwell and the animation are AppKit behaviour and are not covered by
the suite; they were checked by hand. Making them testable would mean a seam
between the panel and the pointer, which is worth doing when something else
needs it, not for its own sake.
