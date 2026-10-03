# 05: Nothing connected — three marks and a way to Settings

**What to build:** With no Provider on, the open surface shows the marks of Codex, Claude Code and OpenCode and one button that opens Settings ▸ Providers, where connecting (and its consent) happens. Redraw 5E2 ("Notch — Disconnected") in Paper first, then build it. Spec story 27.

**Blocked by:** 02, 04.

**Status:** done

- [x] 5E2 redrawn in Paper for three Providers at 210 and agreed with the author before code.
- [x] Nothing connected: three marks, a short line, and one button to Settings ▸ Providers; no per-Provider connect buttons on the surface.
- [x] One connected: the wide one-Provider card (from 01), not a half-empty surface.
- [x] The closed strip with nothing connected unchanged.

## Comments

- 2026-10-02: Done. Redrawn as "Notch — Disconnected · Three Providers" beside the old 5E2 and agreed with the author: an empty strip, the three marks at 28, "Подключите до двух — в настройках", and one "Открыть настройки" button that opens Settings ▸ Providers. `SurfaceCards.shown` gives no card with nothing on; `SurfaceCards.offered` gives the marks, in Provider order. The interim three Connect cards from 04 are gone. The metrics dump now prints `disconnected: column=210.0`; `disconnected.png` in the picture dump is the new view.
