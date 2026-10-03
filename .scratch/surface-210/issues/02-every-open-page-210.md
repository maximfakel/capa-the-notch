# 02: Every open page is 210

**What to build:** The open surface is exactly 210 points on every page — Capacity, music, Teleprompter, Shelf — instead of following its content, so it no longer jumps when pages turn. The closed surface keeps its heights except the Teleprompter's running row, which becomes 210 as drawn. Spec stories 1–5; Paper frames "Expanded — Playing" (5B1), "Expanded — Teleprompter" (5CK), "Compact — Teleprompter running" (53M), the two music "nothing playing" frames.

**Blocked by:** 01.

**Status:** done

- [x] The metrics dump prints the open height of every page and each reads 210 (38 strip + 152 page + 20 dots).
- [x] The music page matches 5B1 (artwork 146), in playing, paused and both nothing-playing states.
- [x] The closed Teleprompter while running is 210 as in 53M; paused as drawn.
- [x] A Provider's explanation that cannot fit is cut to two lines with an ellipsis; Settings still shows it whole.
- [x] Picture dumps of every page compared with the frames.

## Comments

- 2026-10-02: Done. Every page is given 152 under the strip, so the open surface measures 210 on Capacity (every card state), music (playing, paused, both nothing-playing), the Teleprompter and the Shelf; grown into buttons the switcher adds its 14, as before. The closed Teleprompter, reading or paused, is 210 (54K is drawn at 210 too). Under a menu bar shorter than 38 the strip is shorter and the surface with it (204 under 32): the page keeps its 152. A page that outgrew 152 would be cut at the bottom, so the picture dump, not the metrics dump, is where that shows. Settings shows a Provider's whole sentence for stale and disconnected Providers, as before; a connecting Provider with a reason shows it only on the notch.
