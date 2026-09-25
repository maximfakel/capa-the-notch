#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"
app_bundle="$project_root/.build/CapacityNotch.app"

if [[ -n "${CAPACITY_NOTCH_SDKROOT:-}" ]]; then
  export SDKROOT="$CAPACITY_NOTCH_SDKROOT"
fi

swift build --build-system native -c release --product CapacityNotch
swift build --build-system native -c release --product CapacityNotchClaudeBridge
binary_dir="$(swift build --build-system native -c release --product CapacityNotch --show-bin-path)"

rm -rf "$app_bundle"
mkdir -p "$app_bundle/Contents/MacOS"
mkdir -p "$app_bundle/Contents/Resources"
install -m 755 "$binary_dir/CapacityNotch" "$app_bundle/Contents/MacOS/CapacityNotch"
install -m 755 "$binary_dir/CapacityNotchClaudeBridge" "$app_bundle/Contents/MacOS/CapacityNotchClaudeBridge"
install -m 644 "$project_root/Packaging/Info.plist" "$app_bundle/Contents/Info.plist"
install -m 644 "$project_root/Sources/CapacityNotch/Resources/OpenAIBlossom.svg" "$app_bundle/Contents/Resources/OpenAIBlossom.svg"
install -m 644 "$project_root/Sources/CapacityNotch/Resources/MenuBarIcon.svg" "$app_bundle/Contents/Resources/MenuBarIcon.svg"
install -m 644 "$project_root/Packaging/AppIcon.icns" "$app_bundle/Contents/Resources/AppIcon.icns"

# The Music Module's reader (ADR 0004): run by /usr/bin/perl, never loaded here.
mkdir -p "$app_bundle/Contents/Frameworks"
"$script_dir/build-adapter.sh" "$project_root/Vendor/mediaremote-adapter" "$app_bundle/Contents/Frameworks/MediaRemoteAdapter.framework" \
  "$app_bundle/Contents/Helpers/MediaRemoteAdapterTestClient"
install -m 644 "$project_root/Vendor/mediaremote-adapter/bin/mediaremote-adapter.pl" "$app_bundle/Contents/Resources/mediaremote-adapter.pl"

# Hardened Runtime, with no entitlements: nothing here needs JIT, injected
# libraries or a debugger. The bridge is signed on its own and first —
# signing the bundle marks only its main executable — because Claude Code runs
# it directly.
codesign --force --options runtime --sign - "$app_bundle/Contents/MacOS/CapacityNotchClaudeBridge"
# The designated requirement is named rather than left to codesign, which for
# an ad-hoc signature is this build's own hash — so every build was a new
# application to macOS, and it asked again for everything it had been granted.
# Any build of this bundle identifier satisfies this one.
codesign --force --options runtime --sign - \
  -r='designated => identifier "app.capacitynotch.CapacityNotch"' "$app_bundle"
print "$app_bundle"
