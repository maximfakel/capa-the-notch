#!/usr/bin/env bash
# Installs CapaTheNotch for GNOME Shell on Linux, for this user only:
#   - capa-daemon, built in release mode, into ~/.local/bin
#   - capa-claude-bridge, Claude Code's status-line bridge, beside it
#   - its D-Bus service file, so the extension can start it on demand
#   - the CapaTheNotch application entry, which launches it for the session after a Quit
#   - the Geist font the surface is drawn in
#   - the GNOME Shell extension (a symlink with --link, for development)
#
# Usage: linux/scripts/install-linux.sh [--link] [--uninstall]
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # linux/, the Cargo workspace
uuid="capa-the-notch@capathenotch.tech"
bin="$HOME/.local/bin"
services="$HOME/.local/share/dbus-1/services"
fonts="$HOME/.local/share/fonts/CapaTheNotch"
extensions="$HOME/.local/share/gnome-shell/extensions"
icons="$HOME/.local/share/icons/hicolor"
applications="$HOME/.local/share/applications"

if [[ "${1:-}" == "--uninstall" ]]; then
    gnome-extensions disable "$uuid" 2>/dev/null || true
    pkill -x capa-daemon 2>/dev/null || true
    rm -f "$bin/capa-daemon" "$bin/capa-claude-bridge" "$bin/capa-shelf-add" "$services/tech.capathenotch.Daemon.service"
    rm -f "$HOME/.local/share/nautilus/scripts/Add to the CapaTheNotch Shelf"
    rm -rf "$fonts" "$extensions/$uuid"
    find "$icons" -name "tech.capathenotch.CapaTheNotch.png" -delete 2>/dev/null || true
    rm -f "$applications/tech.capathenotch.Settings.desktop" "$applications/tech.capathenotch.DropCatcher.desktop" \
        "$applications/tech.capathenotch.CapaTheNotch.desktop" "$HOME/.config/autostart/capa-the-notch.desktop"
    fc-cache -f >/dev/null 2>&1 || true
    echo "Removed. Settings in ~/.config/capa-the-notch are kept."
    exit 0
fi

cargo build --release --manifest-path "$root/Cargo.toml" -p capa-daemon -p capa-claude-bridge

mkdir -p "$bin" "$services" "$fonts" "$extensions"
install -m 755 "$root/target/release/capa-daemon" "$bin/capa-daemon"
# Claude Code's status line: "statusLine": {"type": "command", "command": "~/.local/bin/capa-claude-bridge"}.
install -m 755 "$root/target/release/capa-claude-bridge" "$bin/capa-claude-bridge"
# The Shelf's way in for files, since the Shell is not told what a drag carries.
install -m 755 "$root/scripts/linux/capa-shelf-add" "$bin/capa-shelf-add"
mkdir -p "$HOME/.local/share/nautilus/scripts"
install -m 755 "$root/scripts/linux/capa-shelf-add" "$HOME/.local/share/nautilus/scripts/Add to the CapaTheNotch Shelf"

cat > "$services/tech.capathenotch.Daemon.service" <<SERVICE
[D-BUS Service]
Name=tech.capathenotch.Daemon
Exec=$bin/capa-daemon
SERVICE

install -m 644 "$root/gnome-extension/$uuid/fonts/Geist.ttf" "$fonts/Geist.ttf"

# The settings window's icon, and the entry that ties its window to it.
mkdir -p "$icons"
cp -r "$root/packaging/icons/hicolor/." "$icons/"
mkdir -p "$applications"
sed -e "s#@SETTINGS_APP@#$extensions/$uuid/settings-app.js#" -e "s#@ICON@#$icons/256x256/apps/tech.capathenotch.CapaTheNotch.png#" \
    "$root/packaging/tech.capathenotch.Settings.desktop.in" \
    > "$applications/tech.capathenotch.Settings.desktop"
# CapaTheNotch itself: launching it shows the extension again after a Quit, as opening the app does on macOS.
sed -e "s#@ICON@#$icons/256x256/apps/tech.capathenotch.CapaTheNotch.png#" \
    "$root/packaging/tech.capathenotch.CapaTheNotch.desktop.in" \
    > "$applications/tech.capathenotch.CapaTheNotch.desktop"
# The window that takes the files dropped on the surface.
sed -e "s#@CATCHER_APP@#$extensions/$uuid/drop-catcher.js#" -e "s#@ICON@#$icons/256x256/apps/tech.capathenotch.CapaTheNotch.png#" \
    "$root/packaging/tech.capathenotch.DropCatcher.desktop.in" \
    > "$applications/tech.capathenotch.DropCatcher.desktop"
gtk-update-icon-cache -q -t "$icons" 2>/dev/null || true
fc-cache -f >/dev/null 2>&1 || true

# The Teleprompter's shortcut keys live in a GSettings schema the shell reads compiled.
glib-compile-schemas "$root/gnome-extension/$uuid/schemas"

rm -rf "$extensions/$uuid"
if [[ "${1:-}" == "--link" ]]; then
    ln -s "$root/gnome-extension/$uuid" "$extensions/$uuid"
else
    cp -rL "$root/gnome-extension/$uuid" "$extensions/$uuid"  # -L: the shared modules are symlinks
fi

# A running daemon is the old one. The bus is told about the new service file,
# which it does not notice by itself when the directory is new.
pkill -x capa-daemon 2>/dev/null || true
busctl --user call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus ReloadConfig >/dev/null 2>&1 || true

echo "Installed. Log out and in once so GNOME Shell finds the extension, then:"
echo "  gnome-extensions enable $uuid"
