#!/bin/sh
# Split the verified v1.1.0 FSR-only Wine runtime into a core archive and a
# D3DMetal overlay. The input tree is only read; no Wine/GPTK build occurs.
#
#   package-wine-runtime-split.sh SOURCE_WINE_ROOT OUTPUT_DIR
#
# Core archive root: wine/
# Backend archive root: lib/ (extract this into wine/ before Wine loads).
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_root=${1:-}
output_dir=${2:-}

core_name=wine-11.17-zzz-core-macos26.tar.xz
backend_name=d3dmetal-gptk4b2-zzz-v1.1.0.tar.xz
backend_version=4.0.0-beta.2.zzz.2
source_runtime_name=wine-11.17-zzz-dx12-gptk4b2-macos26

backend_nodes='external/D3DMetal.framework
external/libd3dshared.dylib
wine/x86_64-windows/d3d10.dll
wine/x86_64-windows/d3d10core.dll
wine/x86_64-windows/d3d11.dll
wine/x86_64-windows/d3d12.dll
wine/x86_64-windows/dxgi.dll
wine/x86_64-windows/nvapi64.dll
wine/x86_64-unix/d3d10.so
wine/x86_64-unix/d3d11.so
wine/x86_64-unix/d3d12.so
wine/x86_64-unix/dxgi.so
wine/x86_64-unix/nvapi64.so'

fail() {
  printf '%s\n' "package-wine-runtime-split: $*" >&2
  exit 1
}

require_path() {
  [ -e "$1" ] || [ -L "$1" ] || fail "missing required node: $1"
}

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

[ "$#" -eq 2 ] && [ -n "$source_root" ] && [ -n "$output_dir" ] || fail "usage: $0 SOURCE_WINE_ROOT OUTPUT_DIR"
[ -d "$source_root" ] || fail "source Wine root is not a directory: $source_root"
source_root=$(CDPATH= cd -- "$source_root" && pwd)
mkdir -p "$output_dir"
output_dir=$(CDPATH= cd -- "$output_dir" && pwd)

for tool_name in ditto tar python3 shasum codesign; do
  command -v "$tool_name" >/dev/null 2>&1 || fail "required tool is unavailable: $tool_name"
done

require_path "$source_root/yaagl-wine-p3-provenance.json"
require_path "$source_root/yaagl-wine-runtime-files.json"
require_path "$source_root/yaagl-wine-p3-graphics-artifacts.json"
require_path "$source_root/zzz-frame-probe-stage.json"
for node in $backend_nodes; do
  require_path "$source_root/lib/$node"
done

# The stage verifier pins every signed graphics/FSR artifact, rejects DLSS
# leftovers, and proves the embedded native/FSR build manifests still match
# the current sources before any payload is copied.
/usr/bin/python3 "$repo_dir/scripts/stage-runtime.py" \
  --verify-runtime "$source_root" --current-sources

# Verify the public identity and the complete monolithic runtime inventory.
/usr/bin/python3 - "$source_root" "$source_runtime_name" <<'PY'
import hashlib
import json
import os
import pathlib
import stat
import sys

root = pathlib.Path(sys.argv[1])
expected_name = sys.argv[2]
with (root / "yaagl-wine-p3-provenance.json").open(encoding="utf-8") as stream:
    provenance = json.load(stream)
with (root / "yaagl-wine-runtime-files.json").open(encoding="utf-8") as stream:
    manifest = json.load(stream)
if provenance.get("name") != expected_name:
    raise SystemExit("source provenance does not identify the v1.1.0 runtime")
if provenance.get("wineVersion") != "wine-11.17":
    raise SystemExit("source provenance does not identify Wine 11.17")
if provenance.get("graphicsBackend") != "d3dmetal":
    raise SystemExit("source provenance does not identify the D3DMetal backend")
if manifest.get("schemaVersion") != 1:
    raise SystemExit("unsupported complete runtime inventory schema")
if manifest.get("runtimeId") != provenance.get("runtimeId"):
    raise SystemExit("runtime inventory and provenance IDs differ")
if manifest.get("wineVersion") != provenance.get("wineVersion"):
    raise SystemExit("runtime inventory and provenance Wine versions differ")

def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

def inventory():
    entries = []
    for directory, names, files in os.walk(root, topdown=True, followlinks=False):
        names.sort()
        files.sort()
        for name in [*names, *files]:
            path = pathlib.Path(directory) / name
            relative = path.relative_to(root).as_posix()
            if relative == "yaagl-wine-runtime-files.json":
                continue
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode):
                entries.append({"path": relative, "type": "symlink", "target": os.readlink(path)})
            elif stat.S_ISREG(mode):
                entries.append({"path": relative, "type": "file", "size": path.stat().st_size,
                                "sha256": sha256(path)})
    entries.sort(key=lambda entry: entry["path"])
    return entries

if manifest.get("entries") != inventory():
    raise SystemExit("complete runtime inventory does not match final staged bytes")
PY
for unix_name in d3d10 d3d11 d3d12 dxgi nvapi64; do
  [ "$(readlink "$source_root/lib/wine/x86_64-unix/$unix_name.so")" = "../../external/libd3dshared.dylib" ] \
    || fail "unexpected bridge symlink: $unix_name.so"
done
codesign --verify --strict --verbose=2 \
  "$source_root/lib/external/D3DMetal.framework" \
  "$source_root/lib/external/D3DMetal.framework/Versions/A/Resources/libYaaglNativePsoCache.dylib" \
  "$source_root/lib/external/D3DMetal.framework/Versions/A/Resources/libmetalirconverter.dylib" \
  "$source_root/lib/external/libd3dshared.dylib" \
  "$source_root/lib/wine/x86_64-unix/amd_fidelityfx_upscaler_dx12.so" \
  "$source_root/lib/wine/x86_64-unix/amd_fidelityfx_framegeneration_dx12.so"

work_root=$(mktemp -d "${TMPDIR:-/tmp}/yaagl-wine-split.XXXXXX")
smoke_prefix=
reassembled_root=
cleanup() {
  status=$?
  if [ -n "$smoke_prefix" ] && [ -n "$reassembled_root" ] && [ -x "$reassembled_root/wine/bin/wineserver" ]; then
    WINEPREFIX="$smoke_prefix" "$reassembled_root/wine/bin/wineserver" -k >/dev/null 2>&1 || :
  fi
  [ -z "$smoke_prefix" ] || rm -rf "$smoke_prefix"
  rm -rf "$work_root"
  exit "$status"
}
trap cleanup 0 1 2 15

core_root="$work_root/core/wine"
backend_root="$work_root/backend/lib"
mkdir -p "$work_root/core" "$work_root/backend"
ditto "$source_root" "$core_root"
mkdir -p "$backend_root/external" "$backend_root/wine/x86_64-windows" "$backend_root/wine/x86_64-unix"
for node in $backend_nodes; do
  mkdir -p "$(dirname -- "$backend_root/$node")"
  mv "$core_root/lib/$node" "$backend_root/$node"
done

# The final manifests describe a monolithic runtime and must not be presented
# as a core-only inventory. Provenance and the stage record stay intact; the
# two split manifests below inventory only their own payloads.
rm -f \
  "$core_root/yaagl-wine-runtime-files.json" \
  "$core_root/yaagl-wine-p3-graphics-artifacts.json"

/usr/bin/python3 - \
  "$source_root" "$core_root" "$backend_root" \
  "$core_name" "$backend_name" "$backend_version" <<'PY'
import hashlib
import json
import os
import pathlib
import stat
import sys

source_root, core_root, backend_root = map(pathlib.Path, sys.argv[1:4])
core_name, backend_name, backend_version = sys.argv[4:7]

def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

def inventory(root, excluded):
    entries = []
    for directory, names, files in os.walk(root, topdown=True, followlinks=False):
        names.sort()
        files.sort()
        for name in [*names, *files]:
            path = pathlib.Path(directory) / name
            relative = path.relative_to(root).as_posix()
            if relative in excluded:
                continue
            info = os.lstat(path)
            entry = {"path": relative, "mode": format(stat.S_IMODE(info.st_mode), "04o")}
            if stat.S_ISLNK(info.st_mode):
                entry.update(type="symlink", target=os.readlink(path))
            elif stat.S_ISDIR(info.st_mode):
                entry["type"] = "directory"
            elif stat.S_ISREG(info.st_mode):
                entry.update(type="file", size=info.st_size, sha256=sha256(path))
            else:
                raise SystemExit(f"unsupported runtime node type: {path}")
            entries.append(entry)
    return entries

with (source_root / "yaagl-wine-p3-provenance.json").open(encoding="utf-8") as stream:
    provenance = json.load(stream)
source_inventory_sha256 = sha256(source_root / "yaagl-wine-runtime-files.json")
source_graphics_sha256 = sha256(source_root / "yaagl-wine-p3-graphics-artifacts.json")
common = {
    "schemaVersion": 1,
    "distribution": "yaagl-wine-split-runtime",
    "runtime": {
        "name": provenance["name"],
        "runtimeId": provenance["runtimeId"],
        "wineVersion": provenance["wineVersion"],
        "sourceRuntimeInventorySha256": source_inventory_sha256,
        "sourceGraphicsManifestSha256": source_graphics_sha256,
    },
    "backend": {
        "archive": backend_name,
        "version": backend_version,
        "archiveRoot": "lib",
        "destinationRelativeToWineRoot": ".",
        "mustInstallBeforeWineLoad": True,
    },
}
core_manifest_name = "yaagl-wine-split-core-files.json"
backend_manifest_name = "yaagl-d3dmetal-backend-files.json"
core = dict(common)
core.update({
    "kind": "core",
    "archive": core_name,
    "archiveRoot": "wine",
    "payloadManifest": core_manifest_name,
    "payloadExcludesOwnManifest": True,
    "sourceMetadataOmitted": [
        "yaagl-wine-runtime-files.json",
        "yaagl-wine-p3-graphics-artifacts.json",
    ],
    "payload": {"entries": inventory(core_root, {core_manifest_name})},
})
backend = dict(common)
backend.update({
    "kind": "d3dmetal-backend-overlay",
    "archive": backend_name,
    "archiveRoot": "lib",
    "payloadManifest": backend_manifest_name,
    "payloadExcludesOwnManifest": True,
    "installation": "Extract this archive's lib/ into the core wine/ directory before invoking wine, wineserver, wineboot, winecfg, or any launcher that loads Wine.",
    "payload": {"entries": inventory(backend_root, {backend_manifest_name})},
})
(core_root / core_manifest_name).write_text(json.dumps(core, indent=2, sort_keys=True) + "\n", encoding="utf-8")
(backend_root / backend_manifest_name).write_text(json.dumps(backend, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

core_archive="$work_root/$core_name"
backend_archive="$work_root/$backend_name"
COPYFILE_DISABLE=1 tar -cJf "$core_archive" -C "$work_root/core" wine
COPYFILE_DISABLE=1 tar -cJf "$backend_archive" -C "$work_root/backend" lib

# Prove archive roots instead of relying on extraction destination conventions.
/usr/bin/python3 - "$core_archive" "$backend_archive" <<'PY'
import sys
import tarfile

for archive, root in zip(sys.argv[1:], ("wine", "lib")):
    with tarfile.open(archive, "r:xz") as stream:
        names = stream.getnames()
    if not names or any(name != root and not name.startswith(root + "/") for name in names):
        raise SystemExit(f"{archive} does not have the required relative {root}/ archive root")
PY

reassembled_root="$work_root/reassembled"
backend_verify_root="$work_root/backend-verify"
mkdir -p "$reassembled_root" "$backend_verify_root"
tar -xJf "$core_archive" -C "$reassembled_root"
tar -xJf "$backend_archive" -C "$backend_verify_root"

# Each manifest inventories only its own archive payload, so validate the core
# before applying the overlay and validate the backend in its own lib/ root.
/usr/bin/python3 - "$reassembled_root/wine" "$backend_verify_root/lib" <<'PY'
import hashlib
import json
import os
import pathlib
import stat
import sys

def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

def inventory(root, excluded):
    entries = []
    for directory, names, files in os.walk(root, topdown=True, followlinks=False):
        names.sort()
        files.sort()
        for name in [*names, *files]:
            path = pathlib.Path(directory) / name
            relative = path.relative_to(root).as_posix()
            if relative in excluded:
                continue
            info = os.lstat(path)
            entry = {"path": relative, "mode": format(stat.S_IMODE(info.st_mode), "04o")}
            if stat.S_ISLNK(info.st_mode):
                entry.update(type="symlink", target=os.readlink(path))
            elif stat.S_ISDIR(info.st_mode):
                entry["type"] = "directory"
            elif stat.S_ISREG(info.st_mode):
                entry.update(type="file", size=info.st_size, sha256=sha256(path))
            else:
                raise SystemExit(f"unsupported runtime node type: {path}")
            entries.append(entry)
    return entries

def verify_manifest(root, manifest_name):
    manifest_path = root / manifest_name
    with manifest_path.open(encoding="utf-8") as stream:
        manifest = json.load(stream)
    if manifest.get("distribution") != "yaagl-wine-split-runtime":
        raise SystemExit(f"unexpected split manifest: {manifest_path}")
    if manifest.get("payloadManifest") != manifest_name:
        raise SystemExit(f"manifest path mismatch: {manifest_path}")
    actual = inventory(root, {manifest_name})
    if manifest.get("payload", {}).get("entries") != actual:
        raise SystemExit(f"manifest inventory does not match payload: {manifest_path}")

core_root, backend_root = map(pathlib.Path, sys.argv[1:3])
verify_manifest(core_root, "yaagl-wine-split-core-files.json")
verify_manifest(backend_root, "yaagl-d3dmetal-backend-files.json")
PY
tar -xJf "$backend_archive" -C "$reassembled_root/wine"

# Validate every original non-manifest runtime node after reassembly: file
# bytes, symlink targets, types, and modes.
/usr/bin/python3 - "$source_root" "$reassembled_root/wine" <<'PY'
import hashlib
import json
import os
import pathlib
import stat
import sys

source_root, reassembled_root = map(pathlib.Path, sys.argv[1:3])
source_excluded = {
    "yaagl-wine-runtime-files.json",
    "yaagl-wine-p3-graphics-artifacts.json",
}
reassembled_excluded = {
    "yaagl-wine-split-core-files.json",
    "lib/yaagl-d3dmetal-backend-files.json",
}

def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

def inventory(root, excluded):
    entries = []
    for directory, names, files in os.walk(root, topdown=True, followlinks=False):
        names.sort()
        files.sort()
        for name in [*names, *files]:
            path = pathlib.Path(directory) / name
            relative = path.relative_to(root).as_posix()
            if relative in excluded:
                continue
            info = os.lstat(path)
            entry = {"path": relative, "mode": format(stat.S_IMODE(info.st_mode), "04o")}
            if stat.S_ISLNK(info.st_mode):
                entry.update(type="symlink", target=os.readlink(path))
            elif stat.S_ISDIR(info.st_mode):
                entry["type"] = "directory"
            elif stat.S_ISREG(info.st_mode):
                entry.update(type="file", size=info.st_size, sha256=sha256(path))
            else:
                raise SystemExit(f"unsupported runtime node type: {path}")
            entries.append(entry)
    return entries

source = inventory(source_root, source_excluded)
reassembled = inventory(reassembled_root, reassembled_excluded)
if source != reassembled:
    source_map = {entry["path"]: entry for entry in source}
    reassembled_map = {entry["path"]: entry for entry in reassembled}
    missing = sorted(source_map.keys() - reassembled_map.keys())
    extra = sorted(reassembled_map.keys() - source_map.keys())
    changed = sorted(path for path in source_map.keys() & reassembled_map.keys() if source_map[path] != reassembled_map[path])
    raise SystemExit("reassembly differs from the immutable runtime: " + json.dumps({"missing": missing, "extra": extra, "changed": changed}))
PY

codesign --verify --strict --verbose=2 \
  "$reassembled_root/wine/lib/external/D3DMetal.framework" \
  "$reassembled_root/wine/lib/external/D3DMetal.framework/Versions/A/Resources/libYaaglNativePsoCache.dylib" \
  "$reassembled_root/wine/lib/external/D3DMetal.framework/Versions/A/Resources/libmetalirconverter.dylib" \
  "$reassembled_root/wine/lib/external/libd3dshared.dylib" \
  "$reassembled_root/wine/lib/wine/x86_64-unix/amd_fidelityfx_upscaler_dx12.so" \
  "$reassembled_root/wine/lib/wine/x86_64-unix/amd_fidelityfx_framegeneration_dx12.so"

# The core intentionally cannot be loaded alone. Exercise only the reassembled
# runtime in a private prefix, then terminate that prefix's wineserver.
smoke_prefix=$(mktemp -d "${TMPDIR:-/tmp}/yaagl-wine-split-prefix.XXXXXX")
WINEPREFIX="$smoke_prefix" WINEARCH=win64 WINEDEBUG=-all \
  "$reassembled_root/wine/bin/wine" wineboot -u
WINEPREFIX="$smoke_prefix" WINEARCH=win64 WINEDEBUG=-all \
  "$reassembled_root/wine/bin/wine" winecfg -v win10
WINEPREFIX="$smoke_prefix" WINEARCH=win64 WINEDEBUG=-all \
  "$reassembled_root/wine/bin/wine" cmd /c exit 0
WINEPREFIX="$smoke_prefix" "$reassembled_root/wine/bin/wineserver" -k
smoke_prefix=

mv -f "$core_archive" "$output_dir/$core_name"
mv -f "$backend_archive" "$output_dir/$backend_name"
(cd "$output_dir" && shasum -a 256 "$core_name") > "$output_dir/$core_name.sha256"
(cd "$output_dir" && shasum -a 256 "$backend_name") > "$output_dir/$backend_name.sha256"

printf '%s\n' "split runtime package complete"
printf '%s\n' "core: $output_dir/$core_name ($(wc -c < "$output_dir/$core_name" | tr -d ' ') bytes, $(sha256_file "$output_dir/$core_name"))"
printf '%s\n' "backend: $output_dir/$backend_name ($(wc -c < "$output_dir/$backend_name" | tr -d ' ') bytes, $(sha256_file "$output_dir/$backend_name"))"
