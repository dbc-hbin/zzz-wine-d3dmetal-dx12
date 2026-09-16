#!/usr/bin/env python3
"""Build and stage a PRIVATE Wine copy. Never edit the installed runtime or game."""
from __future__ import annotations
import argparse, hashlib, json, os, platform, shlex, shutil, subprocess, sys, uuid
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
REL=Path('lib/external/D3DMetal.framework/Versions/A')

def run(args:list[str]) -> None:
    print('+',shlex.join(args),flush=True);subprocess.run(args,check=True)

def under(path:Path,root:Path) -> bool:
    try:path.resolve().relative_to(root.resolve());return True
    except ValueError:return False

def main() -> int:
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--wine-source',required=True,type=Path)
    p.add_argument('--wine-dest',required=True,type=Path)
    p.add_argument('--pristine-d3dmetal',required=True,type=Path)
    p.add_argument('--probe-dir',required=True,type=Path)
    p.add_argument('--build-dir',type=Path,default=ROOT/'build/frame-probe-stage')
    p.add_argument('--check',action='store_true')
    a=p.parse_args();source=a.wine_source.expanduser().resolve();dest=a.wine_dest.expanduser().absolute()
    pristine=a.pristine_d3dmetal.expanduser().resolve();probe=a.probe_dir.expanduser().absolute();build=a.build_dir.expanduser().absolute()
    if dest.exists() or dest.is_symlink():p.error('wine-dest must not already exist')
    if under(dest,source) or under(source,dest):p.error('source and destination must not contain one another')
    if not (source/'bin/wine').is_file() or not (source/REL/'D3DMetal').is_file():p.error('expected the prior ZZZ runtime layout with bin/wine and lib/external/D3DMetal.framework')
    wrapper=(source/'bin/wine').read_text()
    needle='exec "$real_wine" "$@"'
    if not wrapper.startswith('#!') or needle not in wrapper:p.error('unrecognized Wine shell wrapper; refusing to rewrite')
    expected=json.loads((ROOT/'d3dmetal-pso-cache/layout.json').read_text())['source']['sha256']
    actual=hashlib.sha256(pristine.read_bytes()).hexdigest()
    if actual!=expected:p.error(f'pristine D3DMetal SHA mismatch: expected {expected}, got {actual}. Do not supply the already-patched binary.')
    if probe.exists():
        st=probe.lstat()
        if probe.is_symlink() or not probe.is_dir() or st.st_uid!=os.geteuid() or st.st_mode&0o077:p.error('probe-dir must be owned by you, mode 0700, not a symlink')
    if a.check:
        print('PASS: source layout, shell wrapper, destination isolation, pristine D3DMetal identity. No changes.');return 0
    if platform.system()!='Darwin':p.error('staging requires macOS, full Xcode, Node.js and codesign')
    dest.parent.mkdir(parents=True,exist_ok=True)
    probe.mkdir(parents=True,exist_ok=True,mode=0o700)
    build.mkdir(parents=True,exist_ok=True)
    run(['node',str(ROOT/'scripts/build-d3dmetal-pso-cache.mjs'),str(build)])
    temporary=dest.parent/(dest.name+'.staging-'+uuid.uuid4().hex)
    try:
        run(['ditto',str(source),str(temporary)])
        binary=temporary/REL/'D3DMetal';module=temporary/REL/'Resources/libYaaglNativePsoCache.dylib'
        for path in (binary,module,temporary/'bin/wine'):
            if not under(path,temporary):raise RuntimeError(f'copied runtime contains an external replacement symlink: {path}')
        patched=build/'D3DMetal.frame-probe'
        run(['node',str(ROOT/'scripts/d3dmetal-pso-cache-patch.mjs'),'patch',str(pristine),str(patched)])
        shutil.copy2(patched,binary);module.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(build/'libYaaglNativePsoCache.dylib',module)
        run(['codesign','--force','--sign','-',str(module)])
        run(['codesign','--force','--sign','-',str(temporary/'lib/external/D3DMetal.framework')])
        run(['codesign','--verify','--verbose',str(temporary/'lib/external/D3DMetal.framework')])
        checker=ROOT/'scripts/d3dmetal-pso-cache-patch.mjs'
        result=subprocess.check_output(['node',str(checker),'inspect',str(binary)],text=True)
        inspection=json.loads(result)
        if inspection.get('mode') not in ('patched','patched-signed'):raise RuntimeError('post-signature D3DMetal byte-span validation failed')
        helper=temporary/'bin/yaagl-frame-probe-exec'
        # Last-hop helper is after the existing launcher's environment exports.
        # Unlike DYLD_INSERT_LIBRARIES, this is not erased by the old wrapper.
        helper.write_text('''#!/bin/sh
set -eu
export MTL_CAPTURE_ENABLED=1
export YAAGL_METALFX_FRAME_PROBE=1
export YAAGL_METALFX_DIAGNOSTICS=0
unset YAAGL_METALFX_TEMPORAL YAAGL_METALFX_TEMPORAL_TESTS
export YAAGL_METALFX_PROBE_DIR=${YAAGL_METALFX_PROBE_DIR:-'''+shlex.quote(str(probe))+'''}
exec "$@"
''')
        helper.chmod(0o755)
        rewritten=wrapper.replace(needle,'exec "$wrapper_dir/yaagl-frame-probe-exec" "$real_wine" "$@"')
        (temporary/'bin/wine').write_text(rewritten)
        manifest={'diagnostic_only':True,'source_runtime':str(source),'pristine_sha256':actual,'probe_dir':str(probe),
            'binary_inspection':inspection,'native_build_manifest':json.loads((build/'build-manifest.json').read_text()),
            'rendering_changes_by_default':False,'old_temporal_repair_disabled':True}
        (temporary/'zzz-frame-probe-stage.json').write_text(json.dumps(manifest,indent=2)+'\n')
        os.rename(temporary,dest)
    except BaseException:
        if temporary.exists():shutil.rmtree(temporary)
        raise
    print(f'PRIVATE runtime staged: {dest}')
    print(f'Use {dest}/bin/wine in the same launch command/prefix as your normal ZZZ runtime.')
    print('Do not replace the installed Yaagl runtime or use its old package hash manifest to validate this diagnostic copy.')
    print('Rollback: launch the untouched original runtime; delete the private copy when finished.')
    return 0
if __name__=='__main__':
    try:sys.exit(main())
    except (OSError,ValueError,RuntimeError,subprocess.CalledProcessError) as e:sys.exit(str(e))
