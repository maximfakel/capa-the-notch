#!/bin/zsh
# Publishes the version in Packaging/Info.plist as a GitHub release.
#
#   ./Scripts/publish-release.sh            asks before anything leaves the machine
#   ./Scripts/publish-release.sh --dry-run  does everything except push and release
#
# The published repository's history is not this one: it is one snapshot
# commit per release, authored by the GitHub noreply address, so nothing from
# the local history — old fixtures, the author's address — goes with it. So a
# plain push does not apply, and this script does what a push would:
#
# 1. builds the release archive here, from HEAD;
# 2. clones the published repository and commits HEAD's tree onto it, with
#    HEAD's date, so the archive built from it is byte for byte the same;
# 3. sweeps that snapshot for personal data;
# 4. builds the archive again from the snapshot and refuses if it differs;
# 5. pushes, tags, releases as an ordinary release — GitHub never counts a
#    pre-release as latest, and latest is what Check for Updates… opens — and
#    downloads the assets back to check them.
set -euo pipefail

dry_run=false
[[ "${1:-}" == "--dry-run" ]] && dry_run=true

script_dir="${0:A:h}"
project_root="${script_dir:h}"
clone="/tmp/capacity-notch-publish"
cd "$project_root"

fail() { print -u2 "publish-release: $1"; exit 1; }

[[ -z "$(git status --porcelain)" ]] || fail "the working tree has uncommitted changes."

# The repository is named once, where the application opens it.
slug="$(grep -o 'github.com/[^/]*/[^/]*/releases' Sources/CapacityNotchCore/Releases.swift | cut -d/ -f2,3)"
[[ -n "$slug" ]] || fail "could not read the repository from Releases.swift."

version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Packaging/Info.plist)"
tag="v$version"
notes="docs/releases/$version.md"
archive="CapacityNotch-$version.zip"
[[ -f "$notes" ]] || fail "$notes does not exist; write the release notes first."

if gh release view "$tag" --repo "$slug" >/dev/null 2>&1; then
  if $dry_run; then
    print "note: $tag is already released; a real run would stop here."
  else
    fail "$tag is already released. Bump CFBundleShortVersionString in Packaging/Info.plist."
  fi
fi

author="$(gh api user --jq '"\(.id)+\(.login)@users.noreply.github.com"')"
author_name="$(gh api user --jq .login)"
source_date="$(git log -1 --format=%cI)"

print "== building $archive from $(git rev-parse --short HEAD)"
reference="$(./Scripts/build-release.sh | tail -1 | cut -d' ' -f1)"

print "== snapshotting onto $slug"
rm -rf "$clone"
gh repo clone "$slug" "$clone" -- --quiet
git -C "$clone" rm -rq --ignore-unmatch .
git archive HEAD | tar -x -C "$clone"
git -C "$clone" add -A
[[ -n "$(git -C "$clone" status --porcelain)" ]] || fail "the published repository already has this tree."
GIT_AUTHOR_NAME="$author_name" GIT_AUTHOR_EMAIL="$author" GIT_AUTHOR_DATE="$source_date" \
GIT_COMMITTER_NAME="$author_name" GIT_COMMITTER_EMAIL="$author" GIT_COMMITTER_DATE="$source_date" \
  git -C "$clone" commit -q -m "Capacity Notch $version"
[[ "$(git -C "$clone" rev-parse HEAD^{tree})" == "$(git rev-parse HEAD^{tree})" ]] \
  || fail "the snapshot's tree is not HEAD's."

print "== sweeping the snapshot for personal data"
# What would identify the person publishing, read here and now rather than
# written into a file that is itself published.
personal=("${HOME:t}" "$(git config user.email || true)" "$(git config user.name || true)")
found=false
for word in "${personal[@]}"; do
  [[ ${#word} -ge 4 ]] || continue
  if git -C "$clone" grep -q -I -i -F -- "$word"; then
    print -u2 "  the snapshot contains \"$word\":"
    git -C "$clone" grep -n -I -i -F -- "$word" | cut -c1-120 >&2
    found=true
  fi
done
addresses="$(git -C "$clone" grep -h -I -o -E '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' \
  | grep -v -E '^noreply@anthropic\.com$|@example\.(com|org)$|@users\.noreply\.github\.com$' | sort -u || true)"
if [[ -n "$addresses" ]]; then
  print -u2 "  the snapshot contains email addresses:"; print -u2 "$addresses"; found=true
fi
homes="$(git -C "$clone" grep -n -I -E '/Users/[A-Za-z]' \
  | grep -v -E '/Users/(you|someone|jordanlee)\b|/Users/\[' || true)"
if [[ -n "$homes" ]]; then
  print -u2 "  the snapshot contains home directory paths:"; print -u2 "$homes"; found=true
fi
$found && fail "refusing to publish personal data."

print "== building $archive again, from the snapshot"
snapshot="$(cd "$clone" && ./Scripts/build-release.sh | tail -1 | cut -d' ' -f1)"
[[ "$snapshot" == "$reference" ]] \
  || fail "the snapshot built $snapshot, not $reference; the archive is not reproducible."

print ""
print "Ready: $tag on $slug"
print "  commit   $(git -C "$clone" rev-parse --short HEAD) by $author, dated $source_date"
print "  archive  $archive"
print "  sha-256  $reference"
print "  notes    $notes"

if $dry_run; then
  print "Dry run: nothing was pushed or released. The snapshot is in $clone."
  exit 0
fi

print -n "Type \"publish\" to push and release: "
read -r answer
[[ "$answer" == "publish" ]] || fail "not published."

git -C "$clone" push -q origin HEAD
git -C "$clone" tag -a "$tag" -m "Capacity Notch $version"
git -C "$clone" push -q origin "$tag"
# The archive alone. A checksum beside it proves nothing a download from the
# same release could not fake, and GitHub shows each asset's digest itself;
# the reproducibility check above is where the checksum does its work.
gh release create "$tag" --repo "$slug" --latest \
  --title "Capacity Notch $version (beta)" --notes-file "$notes" \
  "$clone/dist/$archive"

print "== checking the release as a download"
check="$(mktemp -d)"
gh release download "$tag" --repo "$slug" --dir "$check"
downloaded="$(shasum -a 256 "$check/$archive" | cut -d' ' -f1)"
[[ "$downloaded" == "$reference" ]] || fail "the downloaded archive is $downloaded, not $reference."
print "$archive: OK"
latest="$(gh api "repos/$slug/releases/latest" --jq .tag_name)"
[[ "$latest" == "$tag" ]] || fail "released, but latest is $latest, not $tag."
print "Published: https://github.com/$slug/releases/tag/$tag"
