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
# native Wayland, so keep forcing xcb rather than letting Qt autodetect.
# Remove these three lines if you want to try native Wayland instead --
# just untested by upstream for this particular build.
export QT_LOGGING_RULES='*=false'
export QT_QPA_PLATFORM=xcb
unset WAYLAND_DISPLAY

cd "$DATADIR/bin"
exec ./LucasR "$@"
