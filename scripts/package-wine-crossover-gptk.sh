#!/bin/sh
# Package the already-installed corrected CrossOver 26.3.0 Wine 11.0 host.
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
host=${1:-"$repo_dir/build/wine-crossover/host"}
provenance=${2:-"$repo_dir/build/wine-crossover/provenance.json"}
backend=${3:-"/Users/hanbinnoh/Library/Application Support/Yaagl ZZZ OS/d3dmetal/d3dmetal-gptk4b2-zzz-v1.0.5.tar.xz"}
out=${4:-"$repo_dir/build/wine-crossover/package-final"}
name=CX26.3.0-wine11.0-msync-gptk4b2.tar.xz
backend_sha=5bbdbdacce3abdc988d432828aa2d652c1c7b103e841c14f0c3b588a076ff66b
server_sha=daaa965d7cf1d25a8eb8391daf99daaeb235d5e64ff9436dbcfb6c83115c59e8
ntdll_sha=16a6248fb35d31bbbf14f9ab0c58f123adf9cf79144bb3333cec52adfe7f4505
comparison="$repo_dir/build/wine-crossover/package/stage/wine"
dep_source=/Users/hanbinnoh/Documents/yaagl-dx12/naposdx12/wine/lib
fail(){ echo "package-wine-crossover-gptk: $*" >&2; exit 1; }
hash(){ shasum -a 256 "$1" | awk '{print $1}'; }
[ "$#" -le 4 ] || fail "usage: $0 [HOST [PROVENANCE [BACKEND [OUTPUT]]]]"
[ -x "$host/bin/wine" ] && [ -x "$host/bin/wineserver" ] || fail "incomplete host"
[ -f "$provenance" ] || fail "missing provenance"
[ "$(hash "$host/bin/wineserver")" = "$server_sha" ] || fail "wrong wineserver"
[ "$(hash "$host/lib/wine/x86_64-unix/ntdll.so")" = "$ntdll_sha" ] || fail "wrong ntdll"
[ "$(hash "$backend")" = "$backend_sha" ] || fail "wrong backend"
[ -d "$comparison/lib/GStreamer.framework" ] || fail "missing verified GStreamer payload"
[ -d "$dep_source" ] || fail "missing dependency closure"
mono="$repo_dir/build/wine-crossover/addons/mono/wine-mono-10.4.1-x86.msi"
gecko="$repo_dir/build/wine-crossover/addons/gecko/wine-gecko-2.47.4-x86.msi"
gecko64="$repo_dir/build/wine-crossover/addons/gecko/wine-gecko-2.47.4-x86_64.msi"
[ "$(hash "$mono")" = 071f4b2887e1c97a11d791ff3d65be9429eed6dec4c2708888bfd546ba358e23 ] || fail "wrong Wine Mono"
[ "$(hash "$gecko")" = 26cecc47706b091908f7f814bddb074c61beb8063318e9efc5a7f789857793d6 ] || fail "wrong x86 Wine Gecko"
[ "$(hash "$gecko64")" = e590b7d988a32d6aa4cf1d8aa3aa3d33766fdd4cf4c89c2dcc2095ecb28d066f ] || fail "wrong x64 Wine Gecko"
work=$(mktemp -d "${TMPDIR:-/tmp}/cx263-package.XXXXXX")
trap 'rm -rf "$work"' 0 1 2 15
mkdir -p "$work/stage"
ditto "$host" "$work/stage/wine"
ditto "$comparison/lib/GStreamer.framework" "$work/stage/wine/lib/GStreamer.framework"
find "$dep_source" -maxdepth 1 -type f -name '*.dylib' -print0 | while IFS= read -r -d '' file; do ditto "$file" "$work/stage/wine/lib/$(basename "$file")"; done
tar -xJf "$backend" -C "$work/stage/wine"
mkdir -p "$work/stage/wine/share/wine/mono" "$work/stage/wine/share/wine/gecko"
ditto "$mono" "$work/stage/wine/share/wine/mono/$(basename "$mono")"
ditto "$gecko" "$work/stage/wine/share/wine/gecko/$(basename "$gecko")"
ditto "$gecko64" "$work/stage/wine/share/wine/gecko/$(basename "$gecko64")"
mv "$work/stage/wine/bin/wine" "$work/stage/wine/bin/wine.real"
cat > "$work/stage/wine/bin/wine" <<'EOF'
#!/bin/sh
set -eu
dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$dir/.." && pwd)
shared="$root/lib/external/libd3dshared.dylib"
[ -x "$dir/wine.real" ] && [ -f "$shared" ] || exit 126
export CX_ACTIVE_GRAPHICS_BACKEND=d3dmetal
export CX_APPLEGPTK_LIBD3DSHARED_PATH="$shared"
export WINEMSYNC="${WINEMSYNC:-1}"
fallback="$root/lib:$root/lib/GStreamer.framework/Versions/1.0/lib"
export DYLD_FALLBACK_LIBRARY_PATH="$fallback${DYLD_FALLBACK_LIBRARY_PATH:+:$DYLD_FALLBACK_LIBRARY_PATH}"
exec "$dir/wine.real" "$@"
EOF
chmod 755 "$work/stage/wine/bin/wine"
ditto "$provenance" "$work/stage/wine/yaagl-wine-crossover-gptk-provenance.json"
# Remove build-machine search paths; changing load commands invalidates signatures,
# so re-sign only the affected source-built Mach-Os with a local ad-hoc identity.
find "$work/stage/wine" -type f -print0 | while IFS= read -r -d '' file; do
  file "$file" | grep -q 'Mach-O' || continue
  rpaths=$(otool -l "$file" | awk 'index($0, "path /Users/") {print $2}')
  [ -n "$rpaths" ] || continue
  printf '%s\n' "$rpaths" | while IFS= read -r rpath; do
    install_name_tool -delete_rpath "$rpath" "$file"
  done
  codesign --force --sign - "$file" >/dev/null 2>&1
done
python3 - "$work/stage/wine" <<'PY'
import hashlib,json,os,pathlib,stat,subprocess,sys
root=pathlib.Path(sys.argv[1]); entries=[]
for p in sorted(root.rglob('*')):
 r=p.relative_to(root).as_posix(); m=p.lstat().st_mode
 if stat.S_ISLNK(m): entries.append({'path':r,'type':'symlink','target':os.readlink(p)})
 elif stat.S_ISREG(m):
  b=p.read_bytes(); entries.append({'path':r,'type':'file','mode':stat.S_IMODE(m),'size':len(b),'sha256':hashlib.sha256(b).hexdigest()})
(root/'yaagl-wine-runtime-files.json').write_text(json.dumps({'schemaVersion':1,'runtimeId':'CX26.3.0-wine11.0-msync-gptk4b2','wineVersion':'wine-11.0','entries':entries},sort_keys=True,separators=(',',':'))+'\n')
for p in root.rglob('*'):
 if p.is_file() and b'Mach-O' in subprocess.run(['file','-b',p],capture_output=True).stdout:
  loads=subprocess.run(['otool','-L',p],capture_output=True,text=True).stdout
  commands=subprocess.run(['otool','-l',p],capture_output=True,text=True).stdout
  if '/Users/' in loads or '/Users/' in commands: raise SystemExit(f'non-relocatable Mach-O: {p}')
PY
codesign --verify --strict "$work/stage/wine/lib/external/libd3dshared.dylib" "$work/stage/wine/lib/external/D3DMetal.framework"
mkdir -p "$out"; rm -rf "$out/stage.next"; mv "$work/stage" "$out/stage.next"; rm -rf "$out/stage"; mv "$out/stage.next" "$out/stage"
COPYFILE_DISABLE=1 tar -cJf "$work/$name" -C "$out/stage" wine
mkdir "$work/check"; tar -xJf "$work/$name" -C "$work/check"
python3 - "$out/stage/wine" "$work/check/wine" <<'PY'
import hashlib,os,pathlib,stat,sys
def scan(root):
 d={}
 for p in pathlib.Path(root).rglob('*'):
  r=p.relative_to(root).as_posix();m=p.lstat().st_mode
  d[r]=('l',os.readlink(p)) if stat.S_ISLNK(m) else ('f',stat.S_IMODE(m),hashlib.sha256(p.read_bytes()).hexdigest()) if stat.S_ISREG(m) else ('d',stat.S_IMODE(m))
 return d
if scan(sys.argv[1])!=scan(sys.argv[2]): raise SystemExit('archive round-trip mismatch')
PY
mv "$work/$name" "$out/$name"; (cd "$out" && shasum -a 256 "$name") > "$out/$name.sha256"
echo "stage: $out/stage/wine"; echo "archive: $out/$name ($(hash "$out/$name"))"
