#!/bin/zsh
# Checks Scripts/signing.sh, the signature both build scripts put on the app
# (ticket 30), against a throwaway certificate in a throwaway keychain: never
# the author's key, which this never touches.
#
#   ./Scripts/test-signing.sh
set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"
source "$script_dir/signing.sh"

work="$(mktemp -d)"
keychain="$work/test.keychain-db"
trap 'security delete-keychain "$keychain" 2>/dev/null || true; rm -rf "$work"' EXIT

failures=0
pass() { print "  ok    $1"; }
fail() { print "  FAIL  $1"; failures=$((failures + 1)); }

# A stand-in CapaTheNotch.app: the two executables the scripts sign, and the
# bundle identifier macOS keys the grants to.
make_app() {
  local app="$1"
  mkdir -p "$app/Contents/MacOS"
  cp /usr/bin/true "$app/Contents/MacOS/CapacityNotch"
  cp /usr/bin/true "$app/Contents/MacOS/CapacityNotchClaudeBridge"
  # Unsigned, as SwiftPM leaves them: /usr/bin/true comes signed by Apple.
  codesign --remove-signature "$app"/Contents/MacOS/*
  cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>CapacityNotch</string>
	<key>CFBundleIdentifier</key>
	<string>app.capacitynotch.CapacityNotch</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
</dict>
</plist>
PLIST
}

entitlements="$project_root/Packaging/CapacityNotch.entitlements"

# The throwaway certificate: self-signed, for code signing, as the author's is.
cat > "$work/cert.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = CapaTheNotch Test
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -config "$work/cert.cnf" \
  -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
openssl pkcs12 -export -legacy -passout pass:test -inkey "$work/key.pem" -in "$work/cert.pem" \
  -out "$work/identity.p12" 2>/dev/null
security create-keychain -p test "$keychain"
security unlock-keychain -p test "$keychain"
security import "$work/identity.p12" -k "$keychain" -P test -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k test "$keychain" >/dev/null 2>&1
rm "$work/key.pem" "$work/identity.p12"
# The certificate's SHA-1, worked out by openssl rather than by signing.sh.
test_hash="$(openssl x509 -in "$work/cert.pem" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d :)"
expected_requirement="designated => identifier \"app.capacitynotch.CapacityNotch\" and certificate leaf = H\"${(L)test_hash}\""
export CAPACITY_NOTCH_SIGNING_KEYCHAIN="$keychain"

print "signing.sh"

# 1. No certificate configured: refuse, and leave the app as it was.
make_app "$work/unconfigured/CapaTheNotch.app"
if (unset CAPACITY_NOTCH_SIGNING_IDENTITY
    CAPACITY_NOTCH_SIGNING_ENV="$work/missing.env" \
      sign_capathenotch "$work/unconfigured/CapaTheNotch.app" "$entitlements") 2>"$work/unconfigured.err"; then
  fail "signs without a configured certificate"
elif codesign -d "$work/unconfigured/CapaTheNotch.app" 2>/dev/null; then
  fail "refused without a certificate, but the app was signed anyway"
elif ! grep -q "Scripts/create-signing-certificate.sh" "$work/unconfigured.err"; then
  fail "refused without a certificate, but did not say how to make one: $(cat "$work/unconfigured.err")"
else
  pass "refuses to sign without a configured certificate, and says how to make one"
fi

# 2. Configured: the app and the bridge carry the certificate, and the app's
#    requirement names it as well as the identifier.
app="$work/signed/CapaTheNotch.app"
make_app "$app"
if ! CAPACITY_NOTCH_SIGNING_IDENTITY="$test_hash" sign_capathenotch "$app" "$entitlements" 2>"$work/signed.err"; then
  fail "does not sign with the configured certificate: $(cat "$work/signed.err")"
else
  requirement="$(codesign -d -r- "$app" 2>/dev/null || true)"
  bridge_authority="$(codesign -dvv "$app/Contents/MacOS/CapacityNotchClaudeBridge" 2>&1 | grep '^Authority=' || true)"
  if [[ "$requirement" != "$expected_requirement" ]]; then
    fail "the requirement is <$requirement>, not <$expected_requirement>"
  elif [[ "$bridge_authority" != "Authority=CapaTheNotch Test" ]]; then
    fail "the bridge is signed by <$bridge_authority>, not by the certificate"
  else
    pass "signs the app and the bridge, and the requirement names the certificate"
  fi
fi

# 3. An impostor: the same app re-signed ad-hoc with the same identifier, as
#    anyone can. It must not satisfy the requirement the real one carries.
impostor="$work/impostor/CapaTheNotch.app"
mkdir -p "${impostor:h}"
ditto "$app" "$impostor"
codesign --force --options runtime --sign - --entitlements "$entitlements" \
  -r='designated => identifier "app.capacitynotch.CapacityNotch"' "$impostor" 2>/dev/null || true
# -R takes the requirement itself, without "designated =>".
genuine_ok=false; impostor_ok=false
codesign --verify -R="${expected_requirement#designated => }" "$app" 2>/dev/null && genuine_ok=true
codesign --verify -R="${expected_requirement#designated => }" "$impostor" 2>/dev/null && impostor_ok=true
if ! codesign --verify "$impostor" 2>/dev/null; then
  fail "the impostor could not be made"
elif ! $genuine_ok; then
  fail "the signed app does not satisfy its own requirement"
elif $impostor_ok; then
  fail "an ad-hoc copy with the same identifier satisfies the requirement"
else
  pass "an ad-hoc copy with the same identifier does not satisfy the requirement"
fi

# 4. The release is rebuilt and compared byte for byte (publish-release.sh),
#    so the same app signed twice must give the same bytes: no signing time.
signed_twice=true
for copy in first second; do
  make_app "$work/$copy/CapaTheNotch.app"
  CAPACITY_NOTCH_SIGNING_IDENTITY="$test_hash" sign_capathenotch "$work/$copy/CapaTheNotch.app" "$entitlements" 2>/dev/null \
    || signed_twice=false
  sleep 1
done
if ! $signed_twice; then
  fail "could not sign the same app twice"
elif diff -r "$work/first/CapaTheNotch.app" "$work/second/CapaTheNotch.app" >/dev/null; then
  pass "signing the same app twice gives the same bytes"
else
  fail "signing the same app twice gives different bytes"
fi

(( failures == 0 )) || { print "$failures failed"; exit 1; }
print "all passed"
