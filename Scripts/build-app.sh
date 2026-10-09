#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"
app_bundle="$project_root/.build/CapaTheNotch.app"
source "$script_dir/signing.sh"
# Before the build, not after it: no certificate, no build (ticket 30).
signing_identity >/dev/null

if [[ -n "${CAPACITY_NOTCH_SDKROOT:-}" ]]; then
  export SDKROOT="$CAPACITY_NOTCH_SDKROOT"
fi

swift build -c release --product CapacityNotch
swift build -c release --product CapacityNotchClaudeBridge
binary_dir="$(swift build -c release --product CapacityNotch --show-bin-path)"

rm -rf "$app_bundle"
mkdir -p "$app_bundle/Contents/MacOS"
mkdir -p "$app_bundle/Contents/Resources"
install -m 755 "$binary_dir/CapacityNotch" "$app_bundle/Contents/MacOS/CapacityNotch"
install -m 755 "$binary_dir/CapacityNotchClaudeBridge" "$app_bundle/Contents/MacOS/CapacityNotchClaudeBridge"
install -m 644 "$project_root/Packaging/Info.plist" "$app_bundle/Contents/Info.plist"
# Keep SwiftPM package resources in the standard app Resources directory.
# Murmur's resolver checks this location before the command-line build path.
for resource_bundle in "$binary_dir"/*.bundle; do
  [[ -d "$resource_bundle" ]] || continue
  ditto "$resource_bundle" "$app_bundle/Contents/Resources/${resource_bundle:t}"
done
install -m 644 "$project_root/Sources/CapacityNotch/Resources/OpenAIBlossom.svg" "$app_bundle/Contents/Resources/OpenAIBlossom.svg"
install -m 644 "$project_root/Sources/CapacityNotch/Resources/MenuBarIcon.tiff" "$app_bundle/Contents/Resources/MenuBarIcon.tiff"
install -m 644 "$project_root/Packaging/AppIcon.icns" "$app_bundle/Contents/Resources/AppIcon.icns"

install -m 644 "$project_root/Sources/CapacityNotch/Resources/DictationLicenses.txt" "$app_bundle/Contents/Resources/DictationLicenses.txt"
# Geist travels with its licence (SIL OFL 1.1), as the licence asks.
install -m 644 "$project_root/Sources/CapacityNotch/Resources/Geist.ttf" "$app_bundle/Contents/Resources/Geist.ttf"
install -m 644 "$project_root/Sources/CapacityNotch/Resources/Geist-OFL.txt" "$app_bundle/Contents/Resources/Geist-OFL.txt"

# The Claude Code mod (ADR 0001, amended 2026-10-08), copied out to
# ~/.claude/skills/capathenotch once the person agrees. Only what it runs:
# its tests stay behind, and the bridge's path is written at install.
for mod_file in .claude-plugin/plugin.json hooks/hooks.json hooks/register.ts; do
  install -d "$app_bundle/Contents/Resources/ClaudeMod/capathenotch/${mod_file:h}"
  install -m 644 "$project_root/Packaging/ClaudeMod/capathenotch/$mod_file" "$app_bundle/Contents/Resources/ClaudeMod/capathenotch/$mod_file"
done

# The Music Module's reader (ADR 0004): run by /usr/bin/perl, never loaded here.
mkdir -p "$app_bundle/Contents/Frameworks"
"$script_dir/build-adapter.sh" "$project_root/Vendor/mediaremote-adapter" "$app_bundle/Contents/Frameworks/MediaRemoteAdapter.framework" \
  "$app_bundle/Contents/Helpers/MediaRemoteAdapterTestClient"
install -m 644 "$project_root/Vendor/mediaremote-adapter/bin/mediaremote-adapter.pl" "$app_bundle/Contents/Resources/mediaremote-adapter.pl"

# Hardened Runtime with the entitlements in Packaging, signed with the author's
# certificate; see signing.sh.
sign_capathenotch "$app_bundle" "$project_root/Packaging/CapacityNotch.entitlements"
print "$app_bundle"
