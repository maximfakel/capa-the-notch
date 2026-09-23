#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"
app_bundle="$project_root/.build/CapacityNotch.app"

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
install -m 644 "$project_root/Sources/CapacityNotch/Resources/OpenAIBlossom.svg" "$app_bundle/Contents/Resources/OpenAIBlossom.svg"

# Hardened Runtime, with no entitlements: nothing here needs JIT, injected
# libraries or a debugger. The bridge is signed on its own and first —
# signing the bundle marks only its main executable — because Claude Code runs
# it directly.
codesign --force --options runtime --sign - "$app_bundle/Contents/MacOS/CapacityNotchClaudeBridge"
codesign --force --options runtime --sign - "$app_bundle"
print "$app_bundle"
