#!/bin/sh
set -e

APPDIR=/app/share/lucaschess
DATADIR="${XDG_DATA_HOME:-$HOME/.local/share}/lucaschess"

mkdir -p "$DATADIR/bin"

for item in Code LucasR.py pyproject.toml; do
  [ -e "$DATADIR/bin/$item" ] || ln -s "$APPDIR/bin/$item" "$DATADIR/bin/$item"
done

# bin/OS is a real copy, kept writable in case an engine writes state next
# to its own binary. Resynced (via mtime stamp) whenever the app's
# FasterCode build changes, not just on first launch, so updates don't
# leave a stale bin/OS/ behind.
FASTERCODE_SO="$(ls "$APPDIR"/bin/OS/linux/FasterCode.*.so 2>/dev/null | head -1)"
APP_STAMP="$([ -n "$FASTERCODE_SO" ] && stat -c %Y "$FASTERCODE_SO" 2>/dev/null)"
OS_STAMP_FILE="$DATADIR/bin/.os-stamp"
if [ ! -e "$DATADIR/bin/OS" ] || [ "$(cat "$OS_STAMP_FILE" 2>/dev/null)" != "$APP_STAMP" ]; then
  rm -rf "$DATADIR/bin/OS"
  cp -r "$APPDIR/bin/OS" "$DATADIR/bin/OS"
  printf '%s' "$APP_STAMP" > "$OS_STAMP_FILE"
fi

[ -e "$DATADIR/Resources" ] || ln -s "$APPDIR/Resources" "$DATADIR/Resources"

# PYTHONPATH picks up both the PySide6/Qt6 BaseApp layer and the
# python3-requirements.json module. Computed from the running interpreter
# rather than hardcoded, so it doesn't break on a runtime Python bump.
PYVER="$(python3 -c 'import sys; print(f"python{sys.version_info[0]}.{sys.version_info[1]}")')"
export PYTHONPATH="/app/lib/$PYVER/site-packages${PYTHONPATH:+:$PYTHONPATH}"
export LD_LIBRARY_PATH="/app/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

cd "$DATADIR/bin"
exec python3 LucasR.py "$@"
