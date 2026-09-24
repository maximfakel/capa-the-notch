#!/bin/zsh
# Builds the release archive: the same bytes from the same commit, every time.
#
# Unlike build-app.sh, which is for the install loop and keeps debug info,
# this one builds for other people. Three things make it reproducible and
# keep the author out of it:
#
# - A fixed scratch path. SwiftPM writes the build directory into the binary
#   (the `Bundle.module` fallback), so a build under a home directory would
#   carry that person's name; a fixed path carries nothing and is the same on
#   every machine.
# - No debug info. The linker's debug map records every object file's path
#   and modification time, which made two clean builds differ and, again,
#   named the home directory.
# - Every file in the bundle stamped with the commit's own time, so the
#   archive does not depend on when it was made.
# - The commit built from a fixed directory of its own, not the checkout. In
#   release the compiler drops a source file's path from a runtime closure
#   check but keeps the path's length, so a build straight from the checkout
#   depended on where it had been cloned.
set -euo pipefail
# touch and zip both read times as local ones; one zone for everybody.
export TZ=UTC

script_dir="${0:A:h}"
project_root="${script_dir:h}"
scratch="/tmp/capacity-notch-release"
source="/tmp/capacity-notch-source"
dist="$project_root/dist"

cd "$project_root"

# What goes into the build must be what the commit says, untracked files
# included: SwiftPM compiles everything under Sources, committed or not.
if [[ -n "$(git status --porcelain -- Sources Packaging Package.swift)" ]]; then
  print -u2 "Sources, Packaging or Package.swift differ from the commit; a release is built from a commit."
  exit 1
fi

version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Packaging/Info.plist)"
commit_time="$(git log -1 --format=%ct)"
stamp="$(date -r "$commit_time" -u +%Y%m%d%H%M.%S)"

rm -rf "$scratch" "$source"
mkdir -p "$source"
git archive HEAD | tar -x -C "$source"

cd "$source"
for product in CapacityNotch CapacityNotchClaudeBridge; do
  swift build -c release --scratch-path "$scratch" --product "$product" -Xswiftc -gnone
done
binaries="$scratch/release"

stage="$scratch/stage"
app="$stage/CapacityNotch.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
install -m 755 "$binaries/CapacityNotch" "$app/Contents/MacOS/CapacityNotch"
install -m 755 "$binaries/CapacityNotchClaudeBridge" "$app/Contents/MacOS/CapacityNotchClaudeBridge"
install -m 644 Packaging/Info.plist "$app/Contents/Info.plist"
install -m 644 Sources/CapacityNotch/Resources/OpenAIBlossom.svg "$app/Contents/Resources/OpenAIBlossom.svg"

# The Music Module's reader (ADR 0004): run by /usr/bin/perl, never loaded here.
mkdir -p "$app/Contents/Frameworks"
"$source/Scripts/build-adapter.sh" "$source/Vendor/mediaremote-adapter" "$app/Contents/Frameworks/MediaRemoteAdapter.framework" \
  "$app/Contents/Helpers/MediaRemoteAdapterTestClient"
install -m 644 Vendor/mediaremote-adapter/bin/mediaremote-adapter.pl "$app/Contents/Resources/mediaremote-adapter.pl"

# Nobody's home directory goes out with the release. The one `/Users/` string
# allowed is Redaction's own pattern for scrubbing them.
for binary in "$app"/Contents/MacOS/* "$app"/Contents/Helpers/* "$app"/Contents/Frameworks/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter; do
  if strings -a "$binary" | grep '^/Users/' | grep -qvxF '/Users/[^/\s]+'; then
    print -u2 "${binary:t} contains a home directory path; refusing to release it."
    exit 1
  fi
done

# Hardened Runtime, with no entitlements; the bridge first and on its own,
# because signing the bundle marks only its main executable.
codesign --force --options runtime --sign - "$app/Contents/MacOS/CapacityNotchClaudeBridge"
# A named designated requirement, so an update keeps what macOS granted the
# last version; see build-app.sh.
codesign --force --options runtime --sign - \
  -r='designated => identifier "app.capacitynotch.CapacityNotch"' "$app"
find "$app" -exec touch -h -t "$stamp" {} +

archive="CapacityNotch-$version.zip"
mkdir -p "$dist"
rm -f "$dist/$archive" "$dist/$archive.sha256"
# Sorted entries, no extra attributes: zip's own order would follow the file
# system, and its extended fields would carry the builder's uid and times.
(cd "$stage" && find CapacityNotch.app | LC_ALL=C sort | zip -X -q -@ "$dist/$archive")
(cd "$dist" && shasum -a 256 "$archive" > "$archive.sha256")

print "$dist/$archive"
cat "$dist/$archive.sha256"
