# The signature on CapaTheNotch (ticket 30), sourced by build-app.sh and
# build-release.sh.
#
# Every build is signed with the author's own self-signed certificate, and its
# designated requirement names that certificate. macOS keeps the requirement
# with each grant — microphone, Accessibility, System Events, Calendars — and
# checks later builds against it alone: naming the certificate means an update
# keeps the grants and a build anyone else signed does not get them.
#
# Which certificate: its SHA-1 or exact name, from CAPACITY_NOTCH_SIGNING_IDENTITY
# or from the git-ignored .signing.env that Scripts/create-signing-certificate.sh
# writes. There is no ad-hoc fallback: without the certificate there is no build.
# CAPACITY_NOTCH_SIGNING_KEYCHAIN points at another keychain than the login
# one; Scripts/test-signing.sh uses it for its throwaway certificate.

signing_root="${${(%):-%x}:A:h:h}"

# Prints the SHA-1 of the one code-signing identity the configuration names,
# or says what is missing and fails.
signing_identity() {
  local wanted="${CAPACITY_NOTCH_SIGNING_IDENTITY:-}"
  local env_file="${CAPACITY_NOTCH_SIGNING_ENV:-$signing_root/.signing.env}"
  if [[ -z "$wanted" && -f "$env_file" ]]; then
    wanted="$(sed -n 's/^CAPACITY_NOTCH_SIGNING_IDENTITY=//p' "$env_file" | tail -1)"
  fi
  if [[ -z "$wanted" ]]; then
    print -u2 "No signing certificate is configured: set CAPACITY_NOTCH_SIGNING_IDENTITY or run Scripts/create-signing-certificate.sh."
    return 1
  fi
  # Untrusted identities count: a self-signed root is never trusted, and
  # codesign signs with it all the same. A name must match exactly.
  local keychain=() identities matches
  [[ -n "${CAPACITY_NOTCH_SIGNING_KEYCHAIN:-}" ]] && keychain=("$CAPACITY_NOTCH_SIGNING_KEYCHAIN")
  if ! identities="$(security find-identity -p codesigning "${keychain[@]}" 2>&1)"; then
    print -u2 "Could not list the signing certificates: $identities"
    return 1
  fi
  matches="$(print -r -- "$identities" \
    | awk -v hash="${(U)wanted}" -v name="\"$wanted\"" \
        '$1 ~ /^[0-9]+\)$/ && ($2 == hash || index($0, name)) { print $2 }' \
    | sort -u)"
  if [[ -z "$matches" ]]; then
    print -u2 "The signing certificate \"$wanted\" is not in the keychain, with its private key; restore it from the backup or run Scripts/create-signing-certificate.sh."
    return 1
  elif [[ "$matches" == *$'\n'* ]]; then
    print -u2 "More than one signing certificate is called \"$wanted\"; name it by its SHA-1 instead."
    return 1
  fi
  print "$matches"
}

# Signs the bundle at $1 with the entitlements at $2.
sign_capathenotch() {
  local app="$1" entitlements="$2" identity
  identity="$(signing_identity)" || return 1
  local keychain=()
  [[ -n "${CAPACITY_NOTCH_SIGNING_KEYCHAIN:-}" ]] && keychain=(--keychain "$CAPACITY_NOTCH_SIGNING_KEYCHAIN")
  # No signing time (--signing-time none, which codesign accepts though its
  # manual does not list it): with one the signature differed on every run,
  # and the release archive is rebuilt and compared byte for byte.
  # Hardened Runtime: no JIT, injected libraries or a debugger. The bridge is
  # signed on its own and first — signing the bundle marks only its main
  # executable — because Claude Code runs it directly.
  codesign --force --options runtime --timestamp=none --signing-time none "${keychain[@]}" --sign "$identity" \
    "$app/Contents/MacOS/CapacityNotchClaudeBridge" || return 1
  # The requirement is named rather than left to codesign: any build of this
  # bundle identifier signed with this certificate is the same application to
  # macOS, so an update keeps what was granted, and nothing else is.
  codesign --force --options runtime --timestamp=none --signing-time none "${keychain[@]}" --sign "$identity" \
    --entitlements "$entitlements" \
    -r="designated => identifier \"app.capacitynotch.CapacityNotch\" and certificate leaf = H\"${(L)identity}\"" \
    "$app"
}
