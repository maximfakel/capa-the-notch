#!/bin/zsh
# Builds MediaRemoteAdapter.framework from Vendor/mediaremote-adapter.
#
#   build-adapter.sh <vendor-directory> <output-framework-path> <output-test-client-path>
#
# The sources and flags are the ones the adapter's own CMakeLists.txt names,
# for arm64 only; see Vendor/mediaremote-adapter/VENDORED.md. The test client
# is what the adapter's `test` command runs when nothing is playing, to tell
# "MediaRemote is closed" apart from "nothing to report".
set -euo pipefail

vendor="${1:A}"
framework="$2"
test_client="$3"

sources=(
  src/adapter/env.m src/adapter/get.m src/adapter/globals.m src/adapter/keys.m
  src/adapter/now_playing.m src/adapter/repeat.m src/adapter/seek.m
  src/adapter/send.m src/adapter/shuffle.m src/adapter/speed.m
  src/adapter/stream.m src/adapter/test.m src/private/MediaRemote.m
  src/utility/Debounce.m src/utility/helpers.m
)

rm -rf "$framework"
mkdir -p "$framework/Versions/A/Resources"
(
  cd "$vendor"
  clang -arch arm64 -O2 -fobjc-arc -fvisibility=default -dynamiclib \
    -Iinclude -Isrc "${sources[@]}" \
    -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
    -install_name @rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter \
    -o "$framework/Versions/A/MediaRemoteAdapter"
)
ln -s A "$framework/Versions/Current"
ln -s Versions/Current/MediaRemoteAdapter "$framework/MediaRemoteAdapter"
ln -s Versions/Current/Resources "$framework/Resources"
cat > "$framework/Versions/A/Resources/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>MediaRemoteAdapter</string>
	<key>CFBundleIdentifier</key>
	<string>com.vandenbe.MediaRemoteAdapter</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1</string>
	<key>CFBundleVersion</key>
	<string>0.1.0</string>
</dict>
</plist>
PLIST
# Ad-hoc, as the adapter's own build signs it. It is loaded by /usr/bin/perl,
# not by CapaTheNotch, so Hardened Runtime is not this signature's to set.
codesign --force --sign - "$framework"

mkdir -p "${test_client:h}"
(
  cd "$vendor"
  clang -arch arm64 -O2 -fobjc-arc -Isrc/test src/test/main.m src/test/NowPlayingTest.m \
    -framework Foundation -framework MediaPlayer -o "$test_client"
)
codesign --force --options runtime --sign - "$test_client"
