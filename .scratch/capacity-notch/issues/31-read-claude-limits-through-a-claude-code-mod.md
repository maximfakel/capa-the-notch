# 31: Read Claude's limits through a Claude Code mod

**What to build:** CapaTheNotch ships a small Claude Code mod that hands the
plan's limits to the existing bridge from every surface Claude Code runs in —
the Claude desktop app's Code tab, VS Code, the terminal — so Claude Code's
Capacity stays fresh without the person opening a terminal. Set up with one
question at launch, like the status line today.

**Blocked by:** none.

**Status:** resolved

**Why:** Since `/usage` stopped printing plan limits (2.1.263) the only source
is the status line, which only the terminal draws. The author works in the
desktop app, so the notch showed a week's use of 16% while it was 34%, and the
refresh arrow could do nothing. Research and a live test:
`docs/research/claude-capacity-beyond-the-terminal.md` — a mod's
`session.measure` hook received both windows with reset times in the desktop
Code tab (2026-10-08).

- [x] **The mod.** `session.measure` → when `rateLimits` changed (and on the
      first measurement), the windows in the status line's JSON shape, piped
      to the bundled bridge (`$.process.run`, stdin). Nothing else is passed:
      no prompt, no transcript, no cost. Runs nothing when `rateLimits` is
      empty.
- [x] **No credentials cross.** The desktop app starts Claude Code with
      `CLAUDE_CODE_OAUTH_TOKEN` and account ids in its environment: the
      bridge is run with those removed, and a test proves the bridge never
      sees them.
- [x] **What the mod may call is fixed.** `claude plugin validate --json`
      lists the mod's hooks and calls; a check fails the build if anything
      beyond `session.measure` and running the bridge appears.
- [x] **Where it lives.** Copied out of the signed bundle into a folder the
      app owns (Claude Code writes type files into a mod's folder), and loaded
      either from `~/.claude/skills/capathenotch/` or through
      `CLAUDE_CODE_PLUGIN_DIRS` in `~/.claude/settings.json`'s `env` — decide
      by a live check, preferring the one that edits nothing.
- [x] **Consent.** One question when Claude Code is connected (and once at
      launch for someone already connected), saying exactly what is added and
      that Turn Off removes it; Turn Off removes the mod and anything added to
      `settings.json`, byte for byte as with the status line.
- [x] **Versions.** Mods need Claude Code 2.1.287 (2.1.286 in the desktop
      app). Older: the status line stays the only source, and Settings says
      why the desktop app's Capacity may lag.
- [x] **The status line stays.** Both sources write the same file; the
      newest reading wins, as today.
- [x] **Refresh says the truth.** With Claude Code, the refresh arrow cannot
      pull: it re-reads and, if nothing is newer, says where the next reading
      comes from and when the last one was.
- [x] **ADR 0001 amended**: Claude Code's mods API named as a Provider-owned
      interface, and the list of what CapaTheNotch's mod may call.
- [x] Checked live in the desktop Code tab: the notch's Claude card moves
      within one reply.

## Done

- **The mod** lives in `Packaging/ClaudeMod/capathenotch/` (`plugin.json`,
  `hooks/hooks.json`, `hooks/register.ts`; `hooks/bridge.ts` is written at
  install with this copy's bridge path; `tests/forwards.test.ts` is not
  shipped). On `session.measure` with `rateLimits` in `changed` (the first
  measurement names it too) it builds `{ session_id, rate_limits: { five_hour,
  seven_day: { used_percentage, resets_at } } }` — `resets_at` in epoch
  seconds, a window without a reset or of another kind (`spend_limit`) left
  out, nothing run when none is left — and pipes it to the bridge through
  `$.process.run`, in `/`. `session_id` is a random id the mod makes per load,
  so the bridge tells sessions apart without Claude Code's id. A bridge that
  cannot run is caught: the measurement is never failed.
- **No credentials cross.** argv is `['/usr/bin/env', '-i', bridge]`: the
  bridge starts with an empty environment (`$.process.run`'s `env` only sets
  variables *over* Claude Code's, so it cannot be an allow-list). The bridge
  finds the home folder from the account, not `HOME` (checked). Two tests:
  the mod's own (`claude plugin test`) holds the argv, no `env`, `cwd: '/'`
  and stdin's two keys; `ClaudeMod.noCredentialsCross` reads the argv out of
  `register.ts`, runs it with `/usr/bin/env` as the stand-in bridge while
  this process holds `CLAUDE_CODE_OAUTH_TOKEN`, account ids, `ANTHROPIC_*`,
  `*_TOKEN`, `*_KEY`, and asserts the stand-in got no variable at all (names
  compared, no value printed).
- **What it may call is fixed.** `ClaudeMod.validatesToItsTwoCalls` runs
  `claude plugin validate --json` on the installed copy and the repository's,
  in a temporary `HOME`/`CLAUDE_CONFIG_DIR`, and fails unless the notes are
  exactly `hooks: session.measure` and `calls: $.process.run`, with no
  errors and no gating hooks; it also runs `claude plugin test`. Checked that
  adding a `$.ui.status` call fails it. Without `claude` it prints
  `SKIPPED — NOT CHECKED` rather than pass quietly.
- **Where it lives: `~/.claude/skills/capathenotch/`.** Plugin loading
  reference (code.claude.com/docs/en/plugins/loading): a directory "that has a
  `.claude-plugin/plugin.json` under `~/.claude/skills/`" loads as
  `<name>@skills-dir`, "the directory loads in place and is never copied",
  personal scope has none of the project-scope restrictions, on by the
  manifest's `defaultEnabled` (set `true`). `CLAUDE_CODE_PLUGIN_DIRS` is
  documented as `@inline` — "It loads for that session only" — and the mods
  reference files it under developing a mod; and it needs `settings.json`.
  So the skills folder: nothing in `settings.json` is touched. Core:
  `ClaudeModSetup` — install copies the three shipped files and writes
  `bridge.ts` and a `.capathenotch` marker (last); re-install rewrites only
  what differs and keeps Claude Code's `.claude-plugin/types/`; a folder by
  that name without the marker, or a link, is refused and never removed;
  uninstall removes only the marked folder. Tested in temporary homes.
- **Consent.** The first Turn On's question names both the status line and
  the mod (when one can run); a later Turn On asks whatever is unanswered in
  one question; someone already connected is asked once at launch — not on a
  launch that already asked about the status line. Turn Off removes the mod.
  An agreed mod is brought up to date at launch (a new version, a moved
  copy). Russian and English.
- **Versions** are read from disk, no `claude` run: the desktop app's
  `~/Library/Application Support/Claude/claude-code/<version>/` folders, and
  `claude` in `~/.local/bin`, `~/.claude/local`, `/opt/homebrew/bin`,
  `/usr/local/bin` (native `versions/<version>`, or the npm package's
  `package.json`). Any Claude Code at 2.1.287 (desktop 2.1.286) is enough;
  older or none found: no question, and Settings ▸ Providers ▸ Claude Code
  says why Capacity may lag outside a terminal.
- **The status line stays**; both write through the same bridge, each its own
  session, and the session that saw a change last is believed
  (`ClaudeMod.newestOfTwoWritersWins` feeds it the mod's exact JSON beside a
  status line repeating a day-old reading).
- **Refresh tells the truth.** For Claude Code, Refresh re-reads; if nothing
  is newer the card shows, for six seconds in the gauges' place, "Updates
  after Claude's next reply · read 2 hours ago" / "Обновится после следующего
  ответа Claude · данные 2 ч назад" (the terminal's wording without the mod),
  and Settings says it too. With the mod, an old reading says a reply
  anywhere renews it, and no reading yet says it appears after Claude's next
  reply.
- **Copy Diagnostics**: `claude-mod-installed` / `-not-installed` /
  `-too-old` / `-refused`; no path.
- **ADR 0001** amended 2026-10-08, with the exact list of what the mod may
  hook and call.

### Not done / not verified

- The live check: nothing was installed into the real home, and hot reloading
  was not turned on. Whether the desktop app's sessions load
  `@skills-dir` plugins (they run with `--setting-sources=user,project,local`)
  is the open question the author's check answers.
- Two bridge runs at the same instant (status line and mod) can still drop
  one session's update — the read-modify-write is not locked; the file is
  never torn (atomic write), and the next reply repairs it.
- A `"capathenotch@skills-dir": false` in someone's settings, or
  `allowManagedModsOnly`, stops the mod; Copy Diagnostics still says
  installed.

## Comments

- 2026-10-08: Opened after the author found Claude's limits a day stale while
  working only in the desktop app. Live test recorded in the research file.

- 2026-10-08: Built on `claude-limits-mod` (from `modules-2026-10-07`); see
  Done. All tests pass, `./Scripts/build-app.sh` bundles the mod under
  `Contents/Resources/ClaudeMod/capathenotch/`. Left for the author: turn
  Claude Code off and on in an installed copy (or relaunch, which asks once),
  answer Set Up, check `~/.claude/skills/capathenotch/` holds the mod with
  this copy's bridge path, start a new desktop Code-tab session, send one
  message, and watch the notch's Claude card move within the reply; `/plugin`
  there should list `capathenotch@skills-dir`. Turn Off should remove the
  folder.

**2026-10-08 — checked live by the author.** The build was installed in
/Applications (0.3.1 backed up in `dist/`). Turning Claude Code on asked once;
after Set Up, `~/.claude/skills/capathenotch/` held the mod with its marker
and `hooks/bridge.ts` naming `/Applications/CapaTheNotch.app/…/
CapacityNotchClaudeBridge`; `~/.claude/settings.json` was unchanged (only the
status line, as before). A new Code-tab session in the desktop app, one
message: at 15:32 the bridge file gained a session of the mod's own id with
five hours 36% (resets 15:50) and the week 35% (resets 11 October 18:00), and
the notch's Claude card moved. The terminal's day-old reading (16%) stays in
the file beside it; the newest wins. Resolved.

- 2026-10-08: Settings ▸ Providers ▸ Claude Code now shows the mod as a row
  of its own — "● Работает" + Удалить, "Не добавлен" + Добавить (installs at
  once, no second question), or "Нужен Claude Code 2.1.287 или новее" — with
  the reason line under the header (the real version when too old) and, while
  the mod is not working, "Обновить из терминала" + "Открыть Терминал". This
  replaces the long lag note described under Versions. Built in ticket 32.
