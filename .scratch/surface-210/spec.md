# Surface 210 — Capacity in gauges, OpenCode, and a Shelf in three tabs

**Status:** ready-for-agent

Agreed with the author on 2026-10-02 in a `grill-with-docs` interview
(Q1–Q23). Paper frames named below are the drawing; where this text and a
frame disagree, the frame stands for looks and this text for behaviour.
Decisions recorded alongside: `CONTEXT.md` (Shelf Module, Shelf Tab,
Clipping, Initial Provider Scope), ADR 0001 amended (OpenCode), ADR 0005
amended (the Clipboard History Module becomes the Shelf's).

## Problem Statement

The open Notch Surface changes height every time a person turns a page —
Capacity stands 252 tall, music 185, the Teleprompter 209 — so the surface
jumps under the pointer. Capacity is drawn as bars, which the author wants
replaced with gauges. People have asked to see OpenCode next to Codex and
Claude Code, and the surface has room for only two Providers. And the Shelf
holds files and clipboard images in one row, while copied text, which people
also want at hand, has nowhere to go.

## Solution

Every page of the open surface is exactly 210 points, as drawn. Capacity is
shown as gauges (variant C): one 270° arc per Quota Window, the share left
large in its middle, the reset in the arc's gap. OpenCode joins as a third
Provider, through its Go plan, with its five-hour and weekly windows; at most
two Providers can be on at once, shown in a fixed order. The Shelf gets three
Shelf Tabs — Files, Screenshots and Clipboard — the last taking over what
the Clipboard History Module was to do, with every rule ADR 0005 set for it.

## User Stories

### Height

1. As a person turning pages on the open surface, I want every page to be the same height, so that the surface does not jump under my pointer.
2. As a person, I want the open surface to be 210 points on Capacity, music, the Teleprompter and the Shelf alike, so that it sits the same over whatever is beneath it.
3. As a person reading a Provider's explanation of why it cannot be read, I want the text to fit in two lines with an ellipsis, so that the surface keeps its height, and the full text in Settings.
4. As a person reading from the Teleprompter while it is closed, I want its running script drawn at 210, as in "Compact — Teleprompter running", so that I can see three lines by the camera.
5. As a person listening to music, I want the music page drawn as in "Expanded — Playing" (artwork 146), so that it fills the same 210 as the other pages.

### Capacity in gauges

6. As a person checking Capacity, I want each Quota Window drawn as an open arc with the share left in the middle and the window's name under it, so that I read it at a glance.
7. As a person, I want the reset time written in the arc's gap, so that I see when a window comes back without looking elsewhere.
8. As a person, I want the arc coloured by Capacity Pace — green at 60% left or more, yellow from 10%, red below — so that it matches the Pace I know.
9. As a person with one Provider on, I want its card across the whole width with its two arcs and, beside each, the window's name, "N% used" and "resets in …", so that the space is used rather than left empty ("Limits — C · One provider").
10. As a person whose Capacity is stale, I want the card dimmed with "Stale" in yellow, so that I do not trust old numbers ("Limits — C · Stale + Connecting").
11. As a person whose Provider is connecting, I want empty arcs as placeholders, so that the card holds its shape while it waits.
12. As a person who has used up a window, I want "0%" in red on a red-tinted arc with the reset in red, so that the empty window is unmistakable ("Limits — C · Exhausted + No data").
13. As a person whose Provider cannot be read, I want "No data" in red and one sentence saying what to do, so that I can fix it.

### OpenCode

14. As an OpenCode Go subscriber, I want to connect OpenCode in Settings, so that its limits appear on the notch.
15. As a person connecting OpenCode, I want to be told first that Capacity Notch will read my OpenCode Go key from OpenCode's own file, ask opencode.ai only for the percentages every five minutes, and keep the key nowhere, so that I consent knowingly.
16. As an OpenCode Go subscriber, I want its five-hour and weekly windows shown like those of the other Providers, so that I compare them in one glance.
17. As a person, I want a window OpenCode marks rate-limited shown as exhausted whatever its percentage, so that the surface agrees with what OpenCode lets me do.
18. As a person who has hit OpenCode's monthly limit, I want "Monthly limit reached · until …" in red in the card's header, so that green arcs do not mislead me when OpenCode refuses to work.
19. As a person without an OpenCode sign-in on this Mac, I want the card to tell me to sign in to OpenCode with `opencode auth login`, so that I know the one step missing.
20. As a person, I want "OpenCode's answer was not understood" when its answer changes shape, so that a broken integration is not shown as zero.
21. As a person, I want to refresh OpenCode by hand from its card, so that I do not wait five minutes.
22. As a person, I want OpenCode's own mark next to its name, so that I recognise it as I recognise Codex and Claude.

### Two Providers at most

23. As a person in Settings, I want to be able to turn on at most two Providers, with the third switch disabled and saying "Turn one off to turn this on", so that the surface never has to fit three.
24. As a person, I want the Providers I have on always shown in the order Codex, Claude Code, OpenCode, so that a Provider keeps its side of the strip whatever order I turned them on in.
25. As a person with two Providers on, I want the first on the left of the closed strip and the second on the right, so that the strip reads as before.
26. As a person with one Provider on, I want its five-hour window on the left of the strip and its week on the right, as today.
27. As a person with no Provider on, I want the open surface to show the three Providers' marks and one button to Settings ▸ Providers, so that I know what can be connected and where (5E2, redrawn).
28. As a person going through onboarding, I want OpenCode offered beside Codex and Claude Code, under the same two-at-most rule, so that I can start with any pair.

### Shelf Tabs

29. As a person on the Shelf page, I want three tabs — Files, Screenshots, Clipboard — so that I find what I set down by kind.
30. As a person, I want the Shelf to open on the tab I used last, so that I return where I was.
31. As a person, I want all three tabs always there, and a tab whose intake is off to say how to turn it on, so that I discover what the Shelf can do.
32. As a person, I want Clear to empty only the tab I am on, so that clearing screenshots does not lose my files.
33. As a person, I want files dropped on the notch under Files, as today, up to 20.
34. As a person, I want screenshots and images copied to the clipboard under Screenshots, up to 20, so that they no longer crowd my files.
35. As a person who turned on screenshot intake, I want each new screenshot macOS saves to its chosen place to appear under Screenshots as a reference to that file, so that I can drag it on without opening Finder.
36. As a person, I want Capacity Notch to ask macOS for access to the screenshot folder only when I turn that intake on, and Settings to say so if access is refused, while screenshots copied to the clipboard keep arriving.
37. As a person who turned on text intake, I want text I copy kept under Clipboard as Clippings, newest first, so that I can put it on the clipboard again.
38. As a person, I want text intake off until I turn it on, on its own switch in the Shelf's settings, so that nothing I copy is kept by surprise.
39. As a person, I want to keep 20 Clippings, or 50 or 100 if I choose, so that the history fits how much I copy.
40. As a person, I want each Clipping gone 24 hours after it was copied, unless I switch that off, so that old secrets do not linger.
41. As a person, I want a text copied again to rise to the top rather than appear twice.
42. As a person, I want a text over 100,000 characters not kept at all, so that I never paste something cut short.
43. As a person using a password manager, I want nothing marked concealed, transient or auto-generated kept, and nothing copied while Passwords, Keychain Access or an application I chose is in front, so that my passwords stay out of it.
44. As a person, I want clicking a Clipping to put it on the clipboard and say "Copied", without pasting anything, so that Capacity Notch needs no Accessibility access.
45. As a person sharing my screen, I want the Shelf hidden from screen sharing and recordings while it holds a Clipping, so that a copied token is never broadcast.
46. As a person, I want everything on the Shelf gone when Capacity Notch quits or the Shelf is switched off, as today.

## Implementation Decisions

- **Fixed height.** The open surface no longer measures its content: it is 210 points on every page (the 38-point strip, 152 of page, and the page dots). Each page is laid out to fit 152; text that cannot fit is limited to two lines. The closed surface keeps its own heights except the Teleprompter's running row, which becomes 210 as drawn.
- **Gauges** are one shared drawing used by every Provider card: an arc of 270° opening downwards, the fraction left filled from the lower-left end, a track at 12% white, the value, the window's label, and the reset in the gap. Colour is the window's Capacity Pace (≥60% green, ≥10% yellow, below red; the frames' 30% was a guess). The wide one-Provider card puts a detail column beside each arc; exhausted windows tint the track red.
- **Provider order and selection** become Core rules: a fixed order (Codex, Claude Code, OpenCode); Preferences refuse a third connected Provider; the cards, the strip's sides and the "nothing connected" view all derive from the same ordered selection. The strip's two sides become "first" and "second" rather than named Providers.
- **OpenCode** is a new Provider case with its own service, status reasons and diagnostics codes, following the Codex and Claude shapes: it reads the key from OpenCode's `auth.json` at each request, keeps nothing between requests, and asks the usage endpoint at most every five minutes and on refresh. Its answer maps `rolling` to the five-hour Quota Window and `weekly` to the seven-day one; `monthly` produces no window, only a status reason when it is rate-limited or used up. A window marked rate-limited maps to nothing left. Missing file or key, refused key, unreachable endpoint and unparsable answer are distinct reasons. Connecting asks for consent first, as Claude Code's connection does (ADR 0001, amended).
- **OpenCode's mark** is OpenCode's own logo (MIT, from its repository's brand assets), reduced to one colour and not redrawn; it is credited in the third-party notices, and the README says Capacity Notch is not affiliated with OpenCode.
- **Shelf model** gains a tab per item kind: files, screenshots (and images), and Clippings, each with its own limit (20, 20, and 20/50/100). Clear acts on one tab. The last tab shown is remembered for the session.
- **Clippings** follow ADR 0005 unchanged (amended 2026-10-02): text only, on their own switch, 24-hour expiry by default, dedupe by rising, 100,000-character cap, the nspasteboard.org markers and frontmost-application exclusions, nothing Capacity Notch itself copied, and the surface excluded from capture while any Clipping is held. The Clipboard History Module is not built separately.
- **Screenshot folder** intake reads macOS's chosen screenshot location, watches it only while the switch is on, takes files created after it was turned on, and holds them as references. Refused folder access is reported in Settings and Copy Diagnostics like `shelf-clipboard-refused`.
- **Ticket 27** stays open for further Providers; it gains the rule that at most two are visible. **Ticket 29** is superseded by the Clipboard tab.

## Testing Decisions

- Tests exercise external behaviour at the highest existing seams, in the project's own test runner: given inputs, what the model says — never how a view is built.
- **Capacity model:** OpenCode's usage answer → Capacity Snapshot (windows, rate-limited as exhausted, monthly as a status reason, each failure as its own reason), with the network replaced by a fake, as the Codex service tests replace the App Server.
- **Provider selection:** the two-at-most rule in Preferences and the fixed order, as seen by the cards, the strip's sides (prior art: compact strip tests) and the nothing-connected and one-Provider cases (prior art: switched-off tests).
- **Shelf model:** tab placement, per-tab limits, Clear on one tab, Clipping expiry, rising, the size cap and every exclusion (prior art: Shelf tests and the clipboard-take tests); which new files in the screenshot folder are taken.
- **Height:** the existing metrics dump prints every page's height and each must read 210; the existing picture dump renders every state for comparison with the Paper frames. Neither is a unit test; both are run before a ticket is closed.

## Out of Scope

- Google Flow and vidIQ (researched; neither offers a way to read its credits that this design accepts).
- OpenCode's Zen balance, the monthly window as a gauge, and a key pasted into Settings.
- More than two Providers visible at once; further Providers (ticket 27).
- Search or pinning in the Clipboard tab; keeping anything on disk.

## Further Notes

- Paper frames, page Notch: "Limits — C · Gauges", "Limits — C · One provider", "Limits — C · Stale + Connecting", "Limits — C · Exhausted + No data", "Limits — C · OpenCode + Codex", "Limits — C · OpenCode alone", "Notch — Disconnected" (5E2, to be redrawn for three Providers), "Notch — Compact — Teleprompter running", "Notch — Expanded — Teleprompter", "Notch — Expanded — Playing", "Notch — Expanded — Music, nothing playing (last track)", "Notch — Expanded — Music, nothing played yet", "Notch — Expanded — Shelf", "Notch — Expanded — Shelf empty".
- The OpenCode usage endpoint is undocumented (anomalyco/opencode PR 16513); anomalyco/opencode issue 42776 asks OpenCode to show the same numbers itself and is worth watching.
