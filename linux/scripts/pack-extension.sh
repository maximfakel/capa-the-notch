#!/usr/bin/env bash
# Packs the GNOME Shell extension as the zip extensions.gnome.org takes
# (gnome-extensions pack): the shared modules are copied in where the source tree
# has symlinks to them, and the compiled schema is left out (the site compiles it).
#
# Usage: linux/scripts/pack-extension.sh [OUT_DIR]      (default: dist/)
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
uuid="capa-the-notch@capathenotch.tech"
out="${1:-$root/dist}"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

cp -rL "$root/gnome-extension/$uuid" "$stage/$uuid"
rm -f "$stage/$uuid/schemas/gschemas.compiled"

extras=()
for entry in "$stage/$uuid"/*; do
    name="$(basename "$entry")"
    case "$name" in
        extension.js|metadata.json|stylesheet.css|schemas) ;;
        *) extras+=("--extra-source=$name") ;;
    esac
done

mkdir -p "$out"
(cd "$stage/$uuid" && gnome-extensions pack --force --out-dir="$out" "${extras[@]}" .)
echo "Packed: $out/$uuid.shell-extension.zip"
unzip -l "$out/$uuid.shell-extension.zip" | tail -1
