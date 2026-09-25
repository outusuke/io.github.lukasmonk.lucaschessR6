#!/bin/sh
set -e

APPDIR=/app/share/lucaschess
DATADIR="${XDG_DATA_HOME:-$HOME/.local/share}/lucaschess"

mkdir -p "$DATADIR"

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


cd "$DATADIR/bin"

# FasterCode.*.so ships under OS/linux, but the frozen PyInstaller build
# (LucasR) only auto-discovers extension modules inside _internal/, so
# "import FasterCode" in Code/Base/Game.py fails with ModuleNotFoundError
# even though the file is right there. Point PYTHONPATH at it so normal
# filesystem-based import finds it as a fallback.
export PYTHONPATH="$DATADIR/bin/OS/linux${PYTHONPATH:+:$PYTHONPATH}"

exec ./LucasR "$@"
