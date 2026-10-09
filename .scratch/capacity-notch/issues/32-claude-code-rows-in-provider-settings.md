# 32: Claude Code's mod and terminal in Settings ▸ Providers

**What to build:** The author's new Settings ▸ Providers (Paper, page
"Settings": "Settings — Providers — Claude mod working", "— Claude mod not
added", "— Claude Code too old for the mod"; decisions of 2026-10-08).
Claude Code's card says why its Capacity may lag, shows the mod with Add or
Remove, and — only while the mod is not working — offers to refresh from a
terminal. Beneath the cards, the strip's window and how often polled
Providers are read.

**Blocked by:** 31.

**Status:** resolved
installed copy is the author's (see Not verified).

- [x] **Reason line** under Claude Code's header: "Без мода лимиты Claude
      обновляются только из терминала."; too old: "Установлен Claude Code
      2.1.250, а моды появились в 2.1.287. Пока лимиты обновляются только из
      терминала." with the real version found; none found: its own line.
      None while the mod works.
- [x] **"Мод в Claude" (?)**: "● Работает" + Удалить; "Не добавлен" +
      Добавить; "Нужен Claude Code 2.1.287 или новее", no button. Добавить
      installs at once (the button is the person's explicit action, no
      second question) and is remembered as agreed; Удалить removes only the
      marked folder and is remembered as not agreed, so a launch does not
      put it back. Both show at once.
- [x] **"Обновить из терминала" (?)** + "Открыть Терминал", only while the
      mod is not working: Terminal opens a `.command` file that runs
      `claude` with no arguments, nothing typed for the person.
- [x] **The "?" notes** ("Что такое мод", and one for the terminal), Russian
      and English; VoiceOver hears "Что такое «Мод в Claude»" / "About Mod
      in Claude".
- [x] **"Лимиты в компактной шторке"**: "5 часов" / "Неделя".
- [x] **"Обновлять данные"**: "Каждую минуту" / "Каждые 5 мин" / "Каждые
      15 мин", and the footnote "Codex обновляется по этому расписанию.
      Claude — сам, после каждого ответа."
- [x] Every button the ordinary white bordered one; nothing blue.

## Done

- **Core.** `ClaudeCodeSettings.of(installed:support:newestVersion:canInstallHere:)`
  (`Sources/CapacityNotchCore/ClaudeCode/ClaudeCodeSettings.swift`) decides
  the rows: working (installed and supported) → Удалить, no terminal;
  not added → Добавить + terminal; too old / none found → no button +
  terminal. Two states the mockups do not draw: a copy outside an
  Applications folder ("Только из CapaTheNotch в «Программах»", no Add that
  would do nothing), and a mod left in place after Claude Code went older
  than mods (not called working; Удалить stays). `SettingsNote` holds the
  two notes. `ClaudeModSupport.newestVersion` names the newest Claude Code
  found (terminal or desktop app), read from disk, nothing run.
- **The terminal.** `ClaudeTerminal` writes `~/Library/Application
  Support/CapacityNotch/Claude Code.command` (0755): `cd "$HOME"`, then
  `exec claude` from the shell's PATH, else from the usual places
  (`~/.local/bin`, `~/.claude/local`, `/opt/homebrew/bin`, `/usr/local/bin`),
  else a one-line "not found". The app opens it with
  `NSWorkspace.open(_:withApplicationAt: Terminal)`. Opening a file in
  Terminal needs no permission; AppleScript `do script` would have needed
  Automation, so it is not used. The file is not quarantined (the app is not
  sandboxed), so Gatekeeper does not ask.
- **The strip's window.** `CompactWindowChoice` is now `fiveHour` / `weekly`
  ("5 часов" / "Неделя"); the default is five hours, as before. It applies
  while two Providers are on — one on shows both its windows, as before.
  The strip never chose by Headline Window by default; "Least left" (the
  third choice) is gone, and one stored reads as five hours. CONTEXT.md's
  Headline Window entry says so.
- **The pace.** The stored `backgroundRefreshSeconds` was never read by the
  refresh loop (the schedule was fixed at five minutes closed, one open).
  Now `Preferences.refreshInterval` (same key; an old value reads as the
  nearest choice) drives `RefreshSchedule.standard.closed(every:)`: closed
  at the chosen pace, open still every minute, failures backing off to no
  less than the chosen pace. The loops weigh the wait again every 15
  seconds, so a new choice — or opening the surface — applies to the wait
  already under way rather than after it. Codex and OpenCode follow it
  (OpenCode's own five-minute floor stays); Claude Code's loop only re-reads
  the bridge file.
- **Tests** (`ClaudeSettings.*`, `Preferences.chosenPaceSetsTheSchedule`,
  `CompactStrip.choice`): rows for each state; the words as drawn, Russian
  and English; Add/Remove shown at once (temporary home); the version
  named; the `.command` script run with `sh` and a stand-in `claude` (on
  PATH, in `~/.local/bin`, none), quotes escaped; the pace mapping; both
  settings round-trip through Preferences.
- **Pictures**: `CAPACITY_NOTCH_DUMP_SETTINGS=<dir>` now also draws
  `providers-mod-working-ru`, `-not-added-ru`/`-en`, `-too-old-ru`, and
  both notes, light and dark, from stand-ins (no real preferences or
  `~/.claude`). Compared with HOQ-0, HSK-0 and HWE-0: same rows, words,
  order and buttons; the app also shows OpenCode's card, which the mockups
  leave out.

### Not verified

- "Открыть Терминал" was not pressed on this Mac (it would start the
  author's Claude Code); the script was run with `sh` only.
- Добавить and Удалить were exercised in temporary homes, not in an
  installed copy; the popover's arrow is the system's, the mockup's card has
  none.

## Comments

- 2026-10-08: Built on `providers-settings` (from `modules-2026-10-07`).

**2026-10-08 — checked by the author in the installed copy.** Удалить removed
`~/.claude/skills/capathenotch` and Добавить put it back; "Открыть Терминал"
started `claude` in Terminal without asking for anything; switching the
strip to Неделя showed the weekly windows. All as designed. Resolved.
