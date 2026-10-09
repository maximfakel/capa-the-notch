#!/bin/zsh
# Ticket 14's spike, run as an application of its own.
#
# Launched through `open`, the spike is its own responsible process to macOS:
# a bundle identifier nothing has ever been granted to, rather than the
# terminal, which may hold Input Monitoring or Accessibility already. What it
# sees is what CapaTheNotch would see with no permission at all.
#
#   Spikes/TrackpadTap/run.sh           guided: about a minute, needs a finger
#   Spikes/TrackpadTap/run.sh probe 30  listens 30 s, nobody asked to touch
set -euo pipefail

here="${0:A:h}"
swift build --package-path "$here" -c release --product trackpad-tap-spike >&2
binary="$(swift build --package-path "$here" -c release --product trackpad-tap-spike --show-bin-path)/trackpad-tap-spike"

app="$here/Results/TrackpadTapSpike.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$binary" "$app/Contents/MacOS/TrackpadTapSpike"
cat > "$app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>tech.capathenotch.spike.trackpad-tap</string>
<key>CFBundleExecutable</key><string>TrackpadTapSpike</string>
<key>CFBundleName</key><string>TrackpadTapSpike</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign --force --options runtime --sign - "$app" 2>/dev/null

if tty -s; then
  terminal="$(tty)"
  open -n -W --stdout "$terminal" --stderr "$terminal" "$app" --args "$@"
else
  # No terminal to speak to (run from a script or an agent): keep the output.
  log="$here/Results/last-run.log"
  open -n -W --stdout "$log" --stderr "$log" "$app" --args "$@"
  cat "$log"
fi
