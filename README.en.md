# CapaTheNotch

[Русский](README.md) · **English**

Codex, Claude Code and OpenCode limits in the MacBook notch — beside the camera, at a
glance. Music, a teleprompter, dictation, a shelf for files, a calendar and a
translator live there too.

**Website:** https://capathenotch.tech/ ·
**Download:** [latest release](https://github.com/maximfakel/capa-the-notch/releases/latest)

A free beta for Apple Silicon Macs running macOS 14 or later.

## What it does

- **Limits.** What is left in the five-hour and weekly windows of Codex,
  Claude Code and OpenCode (its Go plan) — any two at once — when they reset, and whether it will last until then. An alert
  when a window drops below 10%.
- **Music.** What is playing, the artwork, seeking, the controls and the Mac's
  volume — for any player that shows its track in Control Center.
- **Teleprompter.** A Script scrolls right under the camera, so you can read
  and look into the lens — at a set speed, or following your voice as you
  read it aloud. While it runs, the surface is kept out of screen recording
  and sharing.
- **Dictation.** Hold ⌃⌥D (or a shortcut of your own), speak, let go — the text appears at the cursor.
  Recognised entirely on this Mac, with GigaAM.
- **Shelf.** Files dropped on the notch stay at hand until you drag them out;
  new screenshots land there too, and copied text if you turn that on. Kept
  in memory only, and empty after you quit.
- **Calendar.** What is next, ten minutes before it starts — with Join for a
  call link — and the day, week and month when the notch is open.
- **Translator.** Russian ↔ English on this Mac (macOS 26 or later): select
  text anywhere, press ⌃⌥T, then copy the translation or put it in place of
  the selection.
- **Two taps on the trackpad** open the notch from anywhere, if you turn that
  on.

Each module is turned on on its own in Settings. The interface speaks English
and Russian.

## Privacy

- CapaTheNotch asks Codex and Claude Code **without their credentials**:
  Codex through Codex's own App Server, Claude Code through its own status
  line.
- **OpenCode is the one exception.** OpenCode has no way of its own to report
  its limits, so with your consent CapaTheNotch reads your OpenCode Go key
  from OpenCode's own file and asks opencode.ai only for the plan's usage. The
  key is kept nowhere and sent nowhere else.
- **Dictation stays on the Mac.** Audio is never saved. A history of
  recognised text is off unless you turn it on.
- **So does the Translator,** with macOS's own on-device translation; nothing
  translated is kept. Calendar event titles never reach the log or the
  diagnostics.
- Copied diagnostics carry versions, states and timings — no addresses,
  identifiers or dictated text.

## Install

**It is signed with the author's own certificate, not Apple's.** It is not
signed with an Apple Developer ID and not notarized by Apple — that is a paid
membership this project does not have. So:

- **macOS warns you the first time you open it**, because Apple has not
  checked it: macOS does not know the author's certificate. The steps below
  approve this one application; nothing asks you to turn Gatekeeper off, and
  you should not;
- **what you allow is kept across updates — and only for builds the author
  signed.** macOS ties the microphone, Accessibility, System Events and
  Calendars to that certificate, so a copy of CapaTheNotch signed by anyone
  else is another application to it and gets none of them without asking.

**Checking the signature.** In Terminal:

```sh
codesign -dvv /Applications/CapaTheNotch.app 2>&1 | grep Authority
codesign -d -r- /Applications/CapaTheNotch.app
```

The first prints `Authority=CapaTheNotch`; the second ends with
`certificate leaf = H"96f745c0374edf111dd823b633b23c9477efbba5"`, the SHA-1 of the
author's certificate. A different one, or none, was not signed by the author.

1. Download `CapaTheNotch-<version>.zip` from the
   [latest release](https://github.com/maximfakel/capa-the-notch/releases/latest).
2. Open the zip and move `CapaTheNotch.app` to Applications.
3. Open it. macOS says it could not verify the application; close that
   message.
4. Open **System Settings → Privacy & Security**, scroll down, and click
   **Open Anyway** beside CapaTheNotch. When the warning comes back, click
   **Open**.

**Updating.** Choose **Check for Updates…** in Settings → General; it opens
the latest release on GitHub. CapaTheNotch never checks on its own. Quit the
running copy and repeat the steps above with the new zip — step 4 likely
again.

**Coming from Capacity Notch 0.3.0 or earlier.** The application is now
`CapaTheNotch.app`; delete `CapacityNotch.app` from Applications. What you
allowed is kept. If Claude Code's status line runs the bridge from
`CapacityNotch.app`, CapaTheNotch offers on its first launch to point that
path at itself — and opens `~/.claude/settings.json` only after you say yes.

**Coming from 0.3.1 or earlier.** The first launch of 0.4.0 clears, once, the
permissions macOS kept under the old ad-hoc signature and opens onboarding at
Permissions to ask for them again. After that, updates keep them.

## Connecting

**Codex.** Sign in with `codex login` and turn on Codex in Settings →
Providers. CapaTheNotch starts its own `codex app-server` and reads the
limits from it.

**Claude Code.** Turn on Claude Code in Settings → Providers. Claude Code
hands its limits to its status-line command after each answer, so
CapaTheNotch asks once and then sets its bridge as that command in
`~/.claude/settings.json`. A status line you already have keeps running after
the bridge; turning Claude Code off puts back what was there. The limits
appear after your next message in Claude Code in a terminal — the desktop app
and editor extensions run no status line.

With Claude Code 2.1.287 or later (2.1.286 in the Claude desktop app), the same
question also adds a small Claude Code mod in `~/.claude/skills/capathenotch`.
After each reply — in the desktop app's Code tab, VS Code or a terminal — it
hands the bridge the two windows and nothing else, so the limits stay fresh
outside a terminal too. The bridge runs with an empty environment, none of
Claude Code's sign-in in it. Nothing in `settings.json` changes; turning
Claude Code off removes the folder.

The bridge keeps only the time, the percentages and the reset times, and
discards everything else. To set it up by hand instead, the line is:

```json
{
  "statusLine": {
    "type": "command",
    "command": "/Applications/CapaTheNotch.app/Contents/MacOS/CapacityNotchClaudeBridge -- /bin/sh -c '~/.claude/statusline.sh'"
  }
}
```

— without `--` and what follows if you have no status line of your own. See
[Anthropic's status-line documentation](https://code.claude.com/docs/en/statusline).

**OpenCode.** You need an OpenCode Go or Go Plus subscription. Sign in with
`opencode auth login` and turn on OpenCode in Settings → Providers. Every five
minutes, and when you refresh, CapaTheNotch takes the key from
`~/.local/share/opencode/auth.json` and asks `opencode.ai` for the five-hour
and weekly windows. The monthly window is not drawn, but when it is used up
the card says so in red.

Any two of the three Providers can be on at once.

## Guides

- [Claude Code, Codex and OpenCode Go usage limits by plan](https://capathenotch.tech/en/limits/)
- [Claude Code limits](https://capathenotch.tech/en/limits/claude-code/) · [Codex limits](https://capathenotch.tech/en/limits/codex/) · [OpenCode Go limits](https://capathenotch.tech/en/limits/opencode-go/)
- [Hit your Claude Code limit? What to do next](https://capathenotch.tech/en/limits/claude-code-limit-reached/)
- [Claude Code and Codex usage trackers for Mac, compared](https://capathenotch.tech/en/limits/usage-trackers/)
- [MacBook notch apps compared](https://capathenotch.tech/en/compare/notch-apps/) · [Notch teleprompters compared](https://capathenotch.tech/en/compare/notch-teleprompter/)

## Building from source

Apple Silicon, macOS 14+, Xcode with the Metal Toolchain, and Swift 6.

```sh
swift run CapacityNotchTests      # checks
./Scripts/test-signing.sh         # checks the signature, with a throwaway certificate
./Scripts/build-app.sh            # .build/CapaTheNotch.app, signed with your certificate
./Scripts/build-release.sh        # dist/CapaTheNotch-<version>.zip
```

Both build scripts sign with a code-signing certificate and refuse to build
without one. `./Scripts/create-signing-certificate.sh` walks you through
making your own in Keychain Access, once; or name one you have in
`CAPACITY_NOTCH_SIGNING_IDENTITY`. A build you sign is your application to
macOS, not the author's, and asks for its own permissions.

The release archive is reproducible: the same commit, Swift toolchain and
certificate give the same bytes — the signature carries no signing time. So
only the author can rebuild the published archive byte for byte; with your
own certificate, everything but the signature is the same. Views declare
their state with `State(initialValue:)` rather than `@State`, whose macro
plugin ships inside Xcode.

## License

MIT. Third-party parts — sherpa-onnx, ONNX Runtime, Murmur, GigaAM, the Geist
font, the OpenCode logo — are credited in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

CapaTheNotch is not affiliated with, or made by, OpenAI, Anthropic or the
OpenCode team.
