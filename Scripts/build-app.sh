#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"
app_bundle="$project_root/.build/CapaTheNotch.app"

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

# The Music Module's reader (ADR 0004): run by /usr/bin/perl, never loaded here.
mkdir -p "$app_bundle/Contents/Frameworks"
"$script_dir/build-adapter.sh" "$project_root/Vendor/mediaremote-adapter" "$app_bundle/Contents/Frameworks/MediaRemoteAdapter.framework" \
  "$app_bundle/Contents/Helpers/MediaRemoteAdapterTestClient"
install -m 644 "$project_root/Vendor/mediaremote-adapter/bin/mediaremote-adapter.pl" "$app_bundle/Contents/Resources/mediaremote-adapter.pl"

# Hardened Runtime: only microphone input is entitled. No JIT, injected
# libraries or a debugger. The bridge is signed on its own and first —
# signing the bundle marks only its main executable — because Claude Code runs
# it directly.
codesign --force --options runtime --sign - "$app_bundle/Contents/MacOS/CapacityNotchClaudeBridge"
# The designated requirement is named rather than left to codesign, which for
# an ad-hoc signature is this build's own hash — so every build was a new
# application to macOS, and it asked again for everything it had been granted.
# Any build of this bundle identifier satisfies this one.
codesign --force --options runtime --sign - \
  --entitlements "$project_root/Packaging/CapacityNotch.entitlements" \
  -r='designated => identifier "app.capacitynotch.CapacityNotch"' "$app_bundle"
print "$app_bundle"
