#!/bin/sh
#
# Rebuilds FasterCode (Cython + bundled C engine "irina") against the
# runtime's actual Python, since the repo ships a prebuilt .so hard-tagged
# for CPython 3.12 and import fails if the runtime uses a different minor
# version.
# Can also run standalone against a git checkout to sanity-check paths:
#   ./build-fastercode.sh /tmp/lc

set -eu

APPDIR="${1:?usage: $0 APPDIR}"

log() { printf ':: %s\n' "$1"; }
die() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

[ -d "$APPDIR" ] || die "APPDIR doesn't exist: $APPDIR"

IRINA_SRC_DIR="$APPDIR/bin/_fastercode/src/irina"
FASTERCODE_SRC_DIR="$APPDIR/bin/_fastercode/src"
INSTALL_DIR="$APPDIR/bin/OS/linux"

[ -d "$IRINA_SRC_DIR" ] || die "Expected irina C source at $IRINA_SRC_DIR -- \
if upstream's tree layout has changed, update IRINA_SRC_DIR/FASTERCODE_SRC_DIR \
in this script to match."

PYVER=$(python3 -c 'import sys; print(f"python{sys.version_info[0]}.{sys.version_info[1]}")')

# Exact ABI-tagged filename Python's import machinery expects, e.g.
# "FasterCode.cpython-313-x86_64-linux-gnu.so". A bare glob would match a
# stale build for the wrong Python version and install it silently.
EXT_SUFFIX=$(python3 -c 'import sysconfig; print(sysconfig.get_config_var("EXT_SUFFIX"))')
EXPECTED_SO="FasterCode${EXT_SUFFIX}"
log "Building FasterCode for $PYVER (expecting $EXPECTED_SO)"

cd "$IRINA_SRC_DIR"

C_SOURCES="lc.c board.c data.c eval.c hash.c loop.c makemove.c movegen.c \
movegen_piece_to.c search.c util.c pgn.c parser.c polyglot.c"
for f in $C_SOURCES; do
  [ -f "$f" ] || die "Expected C source file '$f' in $IRINA_SRC_DIR but it's \
missing -- upstream's irina source list may have changed; update C_SOURCES \
in this script to match."
done

# -std=gnu17: this source does `typedef char bool;`, which C23 rejects
# since `bool` is now a keyword. Newer GCC defaults to C23-ish, so pin
# explicitly.
# shellcheck disable=SC2086
gcc -std=gnu17 -Wall -O2 -fPIC -fno-strict-aliasing \
  -march=x86-64 -mtune=generic \
  -c $C_SOURCES -DNDEBUG
ar rcs libirina.a ./*.o
mv libirina.a ..
rm -f ./*.o

cd "$FASTERCODE_SRC_DIR"

for f in Faster_Irina.pyx Faster_Polyglot.pyx setup_linux.py; do
  [ -f "$f" ] || die "Expected '$f' in $FASTERCODE_SRC_DIR but it's missing \
-- upstream's FasterCode source layout may have changed; update this \
script to match."
done

rm -f FasterCode.*.so
cat Faster_Irina.pyx Faster_Polyglot.pyx > FasterCode.pyx
PYTHONPATH="/app/lib/$PYVER/site-packages" \
  python3 setup_linux.py build_ext --inplace --verbose

if [ ! -f "$EXPECTED_SO" ]; then
  echo "ERROR: expected $EXPECTED_SO after build_ext but it's not here." >&2
  echo "Files actually produced:" >&2
  ls -la FasterCode*.so 2>&1 >&2 || echo "  (none)" >&2
  exit 1
fi

mkdir -p "$INSTALL_DIR"
rm -f "$INSTALL_DIR"/FasterCode.*.so
install -Dm755 "$EXPECTED_SO" "$INSTALL_DIR/$EXPECTED_SO"
log "Installed $INSTALL_DIR/$EXPECTED_SO"
