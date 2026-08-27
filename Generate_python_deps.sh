#!/usr/bin/env bash
#
# Clones flatpak-builder-tools, runs flatpak-pip-generator against a
# requirements.txt, and drops python3-requirements.json next to the
# manifest. Needs real network + pip; run on your host, not in a sandbox.
#
# Usage:
#   ./generate-python-deps.sh [requirements.txt] [manifest-dir] [output-name]
#
# Defaults: requirements.txt, manifest-dir=., output-name=python3-requirements

set -euo pipefail

REQUIREMENTS_FILE="${1:-requirements.txt}"
MANIFEST_DIR="${2:-.}"
OUTPUT_NAME="${3:-python3-requirements}"

CLONE_DIR="$(mktemp -d)"
trap 'rm -rf "$CLONE_DIR"' EXIT

log() { printf '==> %s\n' "$1"; }
die() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

# --- sanity checks -----------------------------------------------------

command -v git    >/dev/null 2>&1 || die "git is required but not found on PATH."
command -v python3 >/dev/null 2>&1 || die "python3 is required but not found on PATH."
command -v pip3   >/dev/null 2>&1 || die "pip3 is required but not found on PATH."

[ -f "$REQUIREMENTS_FILE" ] || die "Can't find requirements file: $REQUIREMENTS_FILE"
[ -d "$MANIFEST_DIR" ]      || die "Manifest directory doesn't exist: $MANIFEST_DIR"

REQUIREMENTS_FILE="$(cd "$(dirname "$REQUIREMENTS_FILE")" && pwd)/$(basename "$REQUIREMENTS_FILE")"
MANIFEST_DIR="$(cd "$MANIFEST_DIR" && pwd)"

# --- strip Qt-bindings packages the generator refuses to handle ---------
# flatpak-pip-generator exits without writing anything if these are
# present ("Please use the baseapp"), dropping every other package too.

FILTERED_REQUIREMENTS="$CLONE_DIR/requirements-filtered.txt"
QT_BINDINGS_PATTERN='^[[:space:]]*(PySide6|PySide2|PyQt6|PyQt5)([[:space:]=<>!~;#]|$)'

grep -Ev -i "$QT_BINDINGS_PATTERN" "$REQUIREMENTS_FILE" > "$FILTERED_REQUIREMENTS" || true

REMOVED="$(grep -Ei "$QT_BINDINGS_PATTERN" "$REQUIREMENTS_FILE" || true)"
if [ -n "$REMOVED" ]; then
  log "Excluding Qt-bindings package(s) from generator input (must come from a BaseApp instead):"
  printf '    %s\n' $REMOVED
fi

[ -s "$FILTERED_REQUIREMENTS" ] || die "Nothing left to generate after filtering — check $REQUIREMENTS_FILE."

# --- fetch the generator ------------------------------------------------

log "Cloning flatpak-builder-tools (shallow)..."
git clone --depth=1 --quiet \
  https://github.com/flatpak/flatpak-builder-tools.git \
  "$CLONE_DIR/flatpak-builder-tools"

GENERATOR="$CLONE_DIR/flatpak-builder-tools/pip/flatpak-pip-generator"
[ -f "$GENERATOR" ] || die "flatpak-pip-generator not found where expected: $GENERATOR"

# --- the generator's own runtime deps -----------------------------------

log "Setting up an isolated venv for the generator itself..."
python3 -m venv "$CLONE_DIR/venv"
# shellcheck disable=SC1091
source "$CLONE_DIR/venv/bin/activate"
pip install --quiet --upgrade pip
pip install --quiet requirements-parser toposort pyyaml

# --- run it --------------------------------------------------------------

log "Running flatpak-pip-generator against: $FILTERED_REQUIREMENTS"
log "(this downloads every package + transitive dependency to hash it)"

pushd "$CLONE_DIR" >/dev/null
python3 "$GENERATOR" \
  --requirements-file="$FILTERED_REQUIREMENTS" \
  --output "$OUTPUT_NAME"
popd >/dev/null

deactivate

OUTPUT_FILE="$CLONE_DIR/${OUTPUT_NAME}.json"
[ -f "$OUTPUT_FILE" ] || die "Generator ran but $OUTPUT_FILE wasn't produced — check the output above for errors."

# --- sanity-check the result ----------------------------------------------

python3 - "$OUTPUT_FILE" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    data = json.load(f)

# Everything nests under "modules"; a single-requirement output may
# instead be a flat module with a top-level "sources" key.
modules = data.get("modules", [])
if not modules and "sources" in data:
    modules = [data]

if not modules:
    sys.exit("Generated file has zero modules — something went wrong.")

empty = [m.get("name", "?") for m in modules if not m.get("sources")]
if empty:
    sys.exit(
        "These generated submodule(s) have zero sources, meaning pip "
        "failed to resolve/hash them (look for a "
        "\"--require-hashes\" or \"Failed to download\" error earlier "
        "in the output above): " + ", ".join(empty)
    )

n_sources = sum(len(m.get("sources", [])) for m in modules)
print(f"Generated '{data.get('name')}' with {len(modules)} submodule(s), {n_sources} pinned source(s) total.")
PYEOF

# --- catch build-time-only deps (e.g. pillow/psutil needing pybind11) ------
# An sdist (.tar.gz) runs its own build backend, so its [build-system]
# requires must appear earlier in the module list. Wheels skip this.

log "Checking sdist modules for build-time-only dependencies (needs network)..."

python3 - "$OUTPUT_FILE" <<'PYEOF'
import json, re, sys, tarfile, io, urllib.request

path = sys.argv[1]
with open(path) as f:
    data = json.load(f)

modules = data.get("modules", [])
name_to_index = {m["name"]: i for i, m in enumerate(modules)}

def guess_module_name(pypi_name):
    return "python3-" + pypi_name.lower().replace("_", "-")

def fetch_pyproject_requires(url):
    """Download an sdist and pull [build-system] requires out of its
    pyproject.toml, without needing a toml parser."""
    try:
        with urllib.request.urlopen(url, timeout=60) as resp:
            raw = resp.read()
    except Exception as e:
        print(f"    (couldn't fetch {url}: {e})")
        return []
    try:
        tf = tarfile.open(fileobj=io.BytesIO(raw), mode="r:gz")
    except Exception as e:
        print(f"    (couldn't open {url} as tar.gz: {e})")
        return []
    member = next((m for m in tf.getmembers()
                   if m.name.endswith("pyproject.toml") and m.name.count("/") <= 1), None)
    if member is None:
        return []
    content = tf.extractfile(member).read().decode("utf-8", "replace")
    m = re.search(r"\[build-system\](.*?)(\n\[|\Z)", content, re.S)
    if not m:
        return []
    m2 = re.search(r"requires\s*=\s*\[(.*?)\]", m.group(1), re.S)
    if not m2:
        return []
    pkgs = re.findall(r'["\']([^"\']+)["\']', m2.group(1))
    names = []
    for p in pkgs:
        n = re.split(r"[<>=!~\[; ]", p, 1)[0].strip()
        if n:
            names.append(n)
    return names

moved_any = False
for mod in list(modules):
    sdist_urls = [s["url"] for s in mod.get("sources", [])
                  if s.get("type") == "file" and s["url"].endswith(".tar.gz")]
    if not sdist_urls:
        continue
    for url in sdist_urls:
        fname = url.rsplit("/", 1)[-1]
        print(f"  {mod['name']}: inspecting sdist {fname} for build-time deps...")
        for req in fetch_pyproject_requires(url):
            if req.lower() in ("setuptools", "wheel"):
                continue
            dep_mod = guess_module_name(req)
            if dep_mod not in name_to_index:
                print(f"    NOTE: needs '{req}' at build time, no matching module "
                      f"({dep_mod}) found — add it to requirements.txt / check "
                      f"manually if the build fails.")
                continue
            dep_idx = name_to_index[dep_mod]
            cur_idx = name_to_index[mod["name"]]
            if dep_idx > cur_idx:
                print(f"    Reordering: '{dep_mod}' is needed by '{mod['name']}' at "
                      f"build time but comes after it — moving it earlier.")
                dep_obj = modules.pop(dep_idx)
                cur_idx = modules.index(mod)
                modules.insert(cur_idx, dep_obj)
                name_to_index = {m["name"]: i for i, m in enumerate(modules)}
                moved_any = True

data["modules"] = modules
with open(path, "w") as f:
    json.dump(data, f, indent=4)
    f.write("\n")

if moved_any:
    print("  Module order adjusted to satisfy build-time requirements.")
else:
    print("  No build-time-only dependency ordering issues found.")
PYEOF

# --- deliver ---------------------------------------------------------------

DEST="$MANIFEST_DIR/${OUTPUT_NAME}.json"
cp "$OUTPUT_FILE" "$DEST"
log "Wrote $DEST"
log "Reference it in your manifest's modules list as: ${OUTPUT_NAME}.json"
