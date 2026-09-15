#!/bin/sh
set -e

APPDIR=/app/share/lucaschess
DATADIR="${XDG_DATA_HOME:-$HOME/.local/share}/lucaschess"

mkdir -p "$DATADIR"

# This is a frozen PyInstaller build: bin/LucasR and everything it needs
# (its own Python, PySide6, and Qt6 .so files) live together under
# bin/_internal, matched at build time -- that's what avoids the ABI
# mismatch this wrapper used to work around by rebuilding.
#
# It does, however, write a couple of small files (a debug log, an
# sqlite options cache) directly next to the executable, which fails
# under Flatpak's read-only /app. Mirror bin/ into user-writable space
# as a shallow symlink farm: real files can be created there, but the
# multi-GB engines/Qt/Python payload stays as symlinks back into /app,
# so nothing gets duplicated on disk. Re-synced whenever the installed
# app changes, not just on first run.
APP_STAMP=""
if [ -r /.flatpak-info ]; then
  APP_STAMP="$(sed -n 's/^app-commit=//p' /.flatpak-info)"
fi

STAMP_FILE="$DATADIR/.bin-stamp"
if [ ! -e "$DATADIR/bin" ] || [ "$(cat "$STAMP_FILE" 2>/dev/null)" != "$APP_STAMP" ]; then
  rm -rf "$DATADIR/bin"
  cp -a -s "$APPDIR/bin" "$DATADIR/bin"
  printf '%s' "$APP_STAMP" > "$STAMP_FILE"
fi

[ -e "$DATADIR/Resources" ] || ln -s "$APPDIR/Resources" "$DATADIR/Resources"

# Match upstream's own launcher (LucasChessR/LucasR.sh in the release
# archive): this frozen build is tested against X11-via-XWayland, not
# native Wayland. Forcing xcb this way is *why* the system cursor theme
# doesn't show up in-app -- under Wayland-native desktops nothing sets
# the X resource manager property (Xcursor.theme) anymore, so a forced
# XWayland client falls back to Qt's default cursor. Try commenting
# these three lines out first to run native Wayland instead (cursor
# theme then comes straight from the compositor, no config needed). If
# that causes other problems, re-enable xcb and see step 2 in chat for
# a cursor-theme workaround under forced xcb.
# export QT_LOGGING_RULES='*=false'
# export QT_QPA_PLATFORM=xcb
# unset WAYLAND_DISPLAY
#
# --- Fallback: cursor-theme fix if xcb forcing has to stay enabled ---
# If native Wayland (above) causes other problems and you re-enable the
# three lines above, also uncomment this block. It reads your actual
# cursor theme/size from GTK's settings.ini (present on GNOME and most
# other desktops) and exports them as XCURSOR_THEME/XCURSOR_SIZE, which
# libXcursor reads directly -- this is what's missing under forced xcb
# on a Wayland-native desktop, since nothing else sets it there.
# Requires the xdg-config/gtk-3.0:ro finish-arg already in the manifest.
#
# GTK_SETTINGS="$HOME/.config/gtk-3.0/settings.ini"
# if [ -z "${XCURSOR_THEME:-}" ] && [ -r "$GTK_SETTINGS" ]; then
#   THEME="$(sed -n 's/^gtk-cursor-theme-name *= *//p' "$GTK_SETTINGS" | head -1)"
#   SIZE="$(sed -n 's/^gtk-cursor-theme-size *= *//p' "$GTK_SETTINGS" | head -1)"
#   [ -n "$THEME" ] && export XCURSOR_THEME="$THEME"
#   [ -n "$SIZE" ] && export XCURSOR_SIZE="$SIZE"
# fi
# # Fallback if settings.ini didn't have it -- Adwaita ships in most
# # runtimes/desktops and beats Qt's bare default cursor.
# : "${XCURSOR_THEME:=Adwaita}"
# : "${XCURSOR_SIZE:=24}"

cd "$DATADIR/bin"
exec ./LucasR "$@"
