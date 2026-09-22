#!/usr/bin/env python3
"""Stage an isolated RX 9070 FSR-to-MetalFX Wine runtime; never modify the source or game."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
import platform
import re
import shlex
import shutil
import subprocess
import sys
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REL = Path('lib/external/D3DMetal.framework/Versions/A')
# Keep the published filenames so installed staged runtimes remain identifiable.
HELPER_NAME = 'yaagl-frame-probe-exec'
STAGE_MANIFEST = 'zzz-frame-probe-stage.json'
PLAIN_EXEC = 'exec "$real_wine" "$@"'
HELPER_EXEC = 'exec "$wrapper_dir/' + HELPER_NAME + '" "$real_wine" "$@"'
STAGE_SCHEMA = 3
PLAY_PROFILE = 'play'
PLAY_MODEL_POLICY = {'all_gpu': 'system-default'}
FSR_OVERRIDE = 'amd_fidelityfx_upscaler_dx12,amd_fidelityfx_framegeneration_dx12=b'
ORIGINAL_FG_SOURCE = Path('/Applications/Zenless Zone Zero/amd_fidelityfx_framegeneration_dx12.dll')
ORIGINAL_FG_SHA256 = '3f5e674a59b400756e98ef31fd583a4eb08ad567ec8dee362886bc96e55ed347'
ORIGINAL_FG_EXPORTS = ((1, 'ffxConfigure'), (2, 'ffxCreateContext'), (3, 'ffxDestroyContext'),
                       (4, 'ffxDispatch'), (5, 'ffxQuery'))
PRIVATE_FG_PATH = 'lib/wine/x86_64-windows/amd_fidelityfx_framegeneration_dx12_native.dll'
FSR_ARTIFACT_PATHS = (
    'lib/wine/x86_64-windows/amd_fidelityfx_upscaler_dx12.dll',
    'lib/wine/x86_64-unix/amd_fidelityfx_upscaler_dx12.so',
    'lib/wine/x86_64-windows/amd_fidelityfx_framegeneration_dx12.dll',
    'lib/wine/x86_64-unix/amd_fidelityfx_framegeneration_dx12.so', PRIVATE_FG_PATH)
FSR_POLICY = {'implementation': 'builtin-fsr-api-to-metalfx-with-metalfx-frame-interpolation',
              'dll_override': FSR_OVERRIDE, 'native_fg_fallback': PRIVATE_FG_PATH,
              'loader_override': False, 'metal_hud': '1', 'diagnostic_log_environment': 'YAAGL_FSR_LOG'}
ARTIFACT_PATHS = ('bin/wine', 'bin/wine.real', 'bin/' + HELPER_NAME,
    str(REL / 'D3DMetal'), str(REL / 'Resources/libYaaglNativePsoCache.dylib'),
    str(REL / 'Resources/libmetalirconverter.dylib'),
    'lib/wine/x86_64-windows/d3d12.dll', 'lib/wine/x86_64-unix/d3d12.so')
DLSS_ARTIFACT_PATHS = ('lib/wine/x86_64-windows/nvngx.dll', 'lib/wine/x86_64-unix/nvngx.so')


def run(args: list[str]) -> None:
    print('+', shlex.join(args), flush=True)
    subprocess.run(args, check=True)


def under(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except ValueError:
        return False


def artifact_hashes(runtime: Path, paths=ARTIFACT_PATHS + FSR_ARTIFACT_PATHS) -> dict[str, str]:
    result = {}
    for relative in paths:
        path = runtime / relative
        if not under(path, runtime):
            raise ValueError(f'external runtime artifact: {relative}')
        result[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
    return result


def original_fg_provenance(path: Path) -> dict:
    if not path.is_file():
        raise ValueError(f'missing original frame-generation fallback: {path}')
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if digest != ORIGINAL_FG_SHA256:
        raise ValueError(f'original frame-generation SHA mismatch: expected {ORIGINAL_FG_SHA256}, got {digest}')
    readobj = Path('/opt/llvm-mingw-20260616-ucrt-macos-universal/bin/llvm-readobj')
    if not readobj.is_file():
        raise ValueError(f'missing PE inspection tool: {readobj}')
    output = subprocess.check_output([str(readobj), '--coff-exports', str(path)], text=True)
    if 'Format: COFF-x86-64' not in output:
        raise ValueError('original frame-generation fallback is not x86_64 PE')
    exports = tuple((int(ordinal), name) for ordinal, name in re.findall(
        r'Ordinal: (\d+)\s+Name: (\w+)', output))
    if exports != ORIGINAL_FG_EXPORTS:
        raise ValueError(f'original frame-generation exports mismatch: {exports!r}')
    return {'source': str(path), 'runtime_path': PRIVATE_FG_PATH, 'sha256': digest,
            'size': path.stat().st_size, 'architecture': 'COFF-x86-64',
            'exports': [{'ordinal': ordinal, 'name': name} for ordinal, name in exports],
            'source_access': 'read-only', 'loader_override': False}


def helper_script() -> str:
    return '\n'.join([
        '#!/bin/sh', 'set -eu',
        'export WINEDLLOVERRIDES=' + FSR_OVERRIDE,
        'export MTL_HUD_ENABLED=1',
        'export MTL_CAPTURE_ENABLED=0',
        'runtime_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)',
        f'export YAAGL_FSR_FG_NATIVE_DLL="Z:$runtime_root/{PRIVATE_FG_PATH}"',
        'exec "$@"', ''])


def artifact_problems(runtime: Path, recorded) -> list[str]:
    if not isinstance(recorded, dict) or set(recorded) != set(ARTIFACT_PATHS + FSR_ARTIFACT_PATHS):
        return ['signed artifact inventory is missing or incomplete; restage with current tooling']
    try:
        actual = artifact_hashes(runtime)
    except (OSError, ValueError) as error:
        return [str(error)]
    problems = [f'signed runtime artifact changed: {name}' for name in actual if recorded[name] != actual[name]]
    for relative in DLSS_ARTIFACT_PATHS:
        path = runtime / relative
        if path.exists() or path.is_symlink():
            problems.append(f'DLSS-only artifact remains in FSR-only runtime: {relative}')
    return problems


def stage_manifest_report(source: Path) -> list[tuple[str, str]]:
    path = source / STAGE_MANIFEST
    if not path.exists():
        return [('INFO', 'source has no staged-runtime manifest')]
    try:
        data = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        return [('FAIL', str(error))]
    if not isinstance(data, dict) or data.get('stage_schema') != STAGE_SCHEMA:
        return [('FAIL', 'unsupported stage schema; use an intact base runtime and restage with current tooling')]
    problems = artifact_problems(source, data.get('signed_artifacts'))
    if (data.get('profile') != PLAY_PROFILE or data.get('fsr_translator') != FSR_POLICY or
            data.get('model_policy') != PLAY_MODEL_POLICY or data.get('render_size_override') is not False or
            data.get('rendering_changes_by_default') is not True or data.get('dlss_translation') is not False):
        problems.append('unsupported FSR-only rendering policy')
    helper = source / 'bin' / HELPER_NAME
    if not helper.is_file() or helper.read_text() != helper_script():
        problems.append('FSR translator manifest does not match the last-hop helper')
    fallback = data.get('native_fg_fallback')
    expected_exports = [{'ordinal': ordinal, 'name': name} for ordinal, name in ORIGINAL_FG_EXPORTS]
    if (not isinstance(fallback, dict) or fallback.get('runtime_path') != PRIVATE_FG_PATH or
            fallback.get('sha256') != ORIGINAL_FG_SHA256 or fallback.get('architecture') != 'COFF-x86-64' or
            fallback.get('exports') != expected_exports or fallback.get('loader_override') is not False):
        problems.append('native frame-generation fallback provenance is missing or invalid')
    private_fallback = source / PRIVATE_FG_PATH
    if not private_fallback.is_file() or private_fallback.stat().st_mode & 0o222:
        problems.append('renamed native frame-generation fallback is missing or writable')
    d3dmetal_input = data.get('d3dmetal_input')
    if (not isinstance(d3dmetal_input, dict) or d3dmetal_input.get('kind') not in ('pristine', 'patched') or
            not re.fullmatch(r'[0-9a-f]{64}', str(d3dmetal_input.get('sha256', '')))):
        problems.append('recorded D3DMetal input kind or SHA is invalid')
    if problems:
        return [('FAIL', message) for message in problems]
    return [('PASS', 'FSR-only staged runtime policy and signed artifact hashes match')]


def verify_runtime(runtime: Path, current_sources: bool = False) -> list[tuple[str, str]]:
    report = stage_manifest_report(runtime)
    if not (runtime / STAGE_MANIFEST).is_file():
        return [('FAIL', 'staged-runtime manifest is missing')]
    if any(level == 'FAIL' for level, _ in report) or not current_sources:
        return report
    data = json.loads((runtime / STAGE_MANIFEST).read_text())
    for label, key in (('native', 'native_build_manifest'), ('FSR translator', 'fsr_build_manifest')):
        build_manifest = data.get(key)
        sources = build_manifest.get('sources') if isinstance(build_manifest, dict) else None
        if not isinstance(sources, list) or not sources:
            report.append(('FAIL', f'{label} build source inventory is missing'))
            continue
        for source in sources:
            if not isinstance(source, dict) or not isinstance(source.get('path'), str):
                report.append(('FAIL', f'{label} has an invalid source inventory entry'))
                continue
            path = ROOT / source['path']
            if (not under(path, ROOT) or not path.is_file() or
                    hashlib.sha256(path.read_bytes()).hexdigest() != source.get('sha256')):
                report.append(('FAIL', f'build source changed: {source["path"]}'))
    launcher = data.get('source_launcher', {})
    if launcher.get('sha256') != hashlib.sha256((ROOT / 'scripts/wine-launch-wrapper.sh').read_bytes()).hexdigest():
        report.append(('FAIL', 'build source changed: scripts/wine-launch-wrapper.sh'))
    if not any(level == 'FAIL' for level, _ in report):
        report.append(('PASS', 'native, FSR translator, and launcher source hashes match current sources'))
    return report


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--wine-source', type=Path)
    p.add_argument('--wine-dest', type=Path)
    d3dmetal = p.add_mutually_exclusive_group()
    d3dmetal.add_argument('--pristine-d3dmetal', type=Path, help='pinned pre-PSO f864 framework')
    d3dmetal.add_argument('--patched-d3dmetal', type=Path, help='strictly verified current-layout patched framework')
    p.add_argument('--verify-runtime', type=Path)
    p.add_argument('--current-sources', action='store_true')
    p.add_argument('--build-dir', type=Path, default=ROOT / 'build/fsr-stage')
    p.add_argument('--original-fg', type=Path, default=ORIGINAL_FG_SOURCE)
    p.add_argument('--play', action='store_true', help='select ordinary play with automatic captures disabled')
    p.add_argument('--fsr-translator', action='store_true', help='select the FSR-only MetalFX runtime')
    p.add_argument('--check', action='store_true')
    a = p.parse_args()
    if a.verify_runtime:
        if a.wine_source or a.wine_dest or a.pristine_d3dmetal or a.patched_d3dmetal or a.check or a.play or a.fsr_translator:
            p.error('--verify-runtime cannot be combined with staging arguments')
        report = verify_runtime(a.verify_runtime.expanduser().resolve(), a.current_sources)
        for level, message in report:
            print(f'{level}: {message}')
        return int(any(level == 'FAIL' for level, _ in report))
    if not a.wine_source or not a.wine_dest or not (a.pristine_d3dmetal or a.patched_d3dmetal):
        p.error('staging requires --wine-source, --wine-dest and exactly one D3DMetal input')
    if a.current_sources:
        p.error('--current-sources requires --verify-runtime')
    if not a.play or not a.fsr_translator:
        p.error('the FSR-only runtime requires --play --fsr-translator')
    source = a.wine_source.expanduser().resolve()
    dest = a.wine_dest.expanduser().absolute()
    original_fg = a.original_fg.expanduser().resolve()
    d3dmetal_input = (a.patched_d3dmetal or a.pristine_d3dmetal).expanduser().resolve()
    input_kind = 'patched' if a.patched_d3dmetal else 'pristine'
    build = a.build_dir.expanduser().absolute()
    if dest.exists() or dest.is_symlink():
        p.error('wine-dest must not already exist')
    if under(dest, source) or under(source, dest):
        p.error('source and destination must not contain one another')
    if not (source / 'bin/wine').is_file() or not (source / REL / 'D3DMetal').is_file():
        p.error('expected a complete Wine runtime with bin/wine and D3DMetal.framework')
    source_report = stage_manifest_report(source)
    failed = [message for level, message in source_report if level == 'FAIL']
    if failed:
        p.error('; '.join(failed))
    launcher_path = ROOT / 'scripts/wine-launch-wrapper.sh'
    wrapper = launcher_path.read_text()
    if not wrapper.startswith('#!') or PLAIN_EXEC not in wrapper:
        p.error('committed Wine launcher has no recognized wine.real launch hop')
    actual = hashlib.sha256(d3dmetal_input.read_bytes()).hexdigest()
    checker = ROOT / 'scripts/d3dmetal-pso-cache-patch.mjs'
    if input_kind == 'pristine':
        expected = json.loads((ROOT / 'd3dmetal-pso-cache/layout.json').read_text())['source']['sha256']
        if actual != expected:
            p.error(f'pristine D3DMetal SHA mismatch: expected {expected}, got {actual}')
    else:
        inspection = json.loads(subprocess.check_output(['node', str(checker), 'inspect', str(d3dmetal_input)], text=True))
        if inspection.get('mode') not in ('patched', 'patched-signed'):
            p.error('patched D3DMetal must pass the current pinned layout and payload inspection')
    fg_provenance = original_fg_provenance(original_fg)
    if a.check:
        print(f'PASS: isolated destination, {input_kind} D3DMetal identity, and pinned native FSR provider verified')
        print('PASS: source launcher will be replaced with the committed RX 9070 wrapper and portable FSR-only helper')
        print('No changes.')
        return 0
    if platform.system() != 'Darwin':
        p.error('staging requires macOS, full Xcode, Node.js and codesign')
    dest.parent.mkdir(parents=True, exist_ok=True)
    build.mkdir(parents=True, exist_ok=True)
    run(['node', str(ROOT / 'scripts/build-d3dmetal-pso-cache.mjs'), str(build)])
    fsr_build = build / 'fsr-translator'
    run([str(ROOT / 'scripts/build-fsr-translator.sh'), str(fsr_build)])
    temporary = dest.parent / (dest.name + '.staging-' + uuid.uuid4().hex)
    try:
        run(['ditto', str(source), str(temporary)])
        binary = temporary / REL / 'D3DMetal'
        module = temporary / REL / 'Resources/libYaaglNativePsoCache.dylib'
        for path in (binary, module, temporary / 'bin/wine', temporary / 'bin' / HELPER_NAME,
                     *(temporary / relative for relative in FSR_ARTIFACT_PATHS)):
            if not under(path, temporary):
                raise RuntimeError(f'copied runtime contains an external replacement symlink: {path}')
        for relative in DLSS_ARTIFACT_PATHS:
            (temporary / relative).unlink(missing_ok=True)
        if input_kind == 'pristine':
            patched = build / 'D3DMetal.fsr-only'
            run(['node', str(checker), 'patch', str(d3dmetal_input), str(patched)])
            shutil.copy2(patched, binary)
        else:
            shutil.copy2(d3dmetal_input, binary)
        module.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(build / 'libYaaglNativePsoCache.dylib', module)
        for relative in FSR_ARTIFACT_PATHS[:-1]:
            target = temporary / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(fsr_build / relative, target)
        fallback = temporary / PRIVATE_FG_PATH
        fallback.unlink(missing_ok=True)
        shutil.copy2(original_fg, fallback)
        fallback.chmod(0o444)
        if original_fg_provenance(fallback)['sha256'] != fg_provenance['sha256']:
            raise RuntimeError('copied native FSR provider changed during staging')
        for path in (temporary / FSR_ARTIFACT_PATHS[1], temporary / FSR_ARTIFACT_PATHS[3], module):
            run(['codesign', '--force', '--sign', '-', str(path)])
        framework = temporary / 'lib/external/D3DMetal.framework'
        run(['codesign', '--force', '--sign', '-', str(framework)])
        run(['codesign', '--verify', '--strict', '--verbose=2', str(framework)])
        inspection = json.loads(subprocess.check_output(['node', str(checker), 'inspect', str(binary)], text=True))
        if inspection.get('mode') not in ('patched', 'patched-signed'):
            raise RuntimeError('post-signature D3DMetal byte-span validation failed')
        helper = temporary / 'bin' / HELPER_NAME
        helper.write_text(helper_script())
        helper.chmod(0o755)
        (temporary / 'bin/wine').write_text(wrapper.replace(PLAIN_EXEC, HELPER_EXEC))
        (temporary / 'bin/wine').chmod(0o755)
        manifest = {
            'stage_schema': STAGE_SCHEMA, 'profile': PLAY_PROFILE, 'diagnostic_only': False,
            'rendering_changes_by_default': True, 'render_size_override': False,
            'model_policy': PLAY_MODEL_POLICY.copy(), 'dlss_translation': False,
            'source_runtime': str(source), 'source_launcher': {
                'path': 'scripts/wine-launch-wrapper.sh', 'sha256': hashlib.sha256(wrapper.encode()).hexdigest()},
            'launcher_helper': {'path': 'bin/' + HELPER_NAME, 'game_launch_only': False},
            'd3dmetal_input': {'kind': input_kind, 'sha256': actual}, 'binary_inspection': inspection,
            'native_build_manifest': json.loads((build / 'build-manifest.json').read_text()),
            'fsr_build_manifest': json.loads((fsr_build / 'build-manifest.json').read_text()),
            'fsr_translator': FSR_POLICY.copy(), 'native_fg_fallback': fg_provenance,
            'signed_artifacts': artifact_hashes(temporary)}
        (temporary / STAGE_MANIFEST).write_text(json.dumps(manifest, indent=2) + '\n')
        problems = [message for level, message in verify_runtime(temporary, current_sources=True) if level == 'FAIL']
        if problems:
            raise RuntimeError('; '.join(problems))
        os.rename(temporary, dest)
    except BaseException:
        if temporary.exists():
            shutil.rmtree(temporary)
        raise
    print(f'FSR-only runtime staged: {dest}')
    print('RX 9070 wrapper; FSR upscaling and MetalFX frame interpolation; original FSR swapchain/provider retained.')
    print('System-default MetalFX model, unchanged game sizing, no DLSS modules or automatic GPU capture.')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
