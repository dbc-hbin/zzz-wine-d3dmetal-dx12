#!/usr/bin/env python3
"""Refresh final-byte metadata in the staged FSR-only runtime tree.

Rewrites ONLY the four metadata files of the staged runtime:
  yaagl-wine-p3-graphics-artifacts.json
  yaagl-wine-p3-provenance.json
  yaagl-wine-runtime-files.json
  yaagl-wine-p3-runtime.txt

It never touches bin/, DLLs, the D3DMetal framework, zzz-frame-probe-stage.json,
or the signed_artifacts recorded there. The stage manifest is treated as an
immutable record: every signed artifact it lists is re-hashed from the staged
tree and must match before anything is written.

usage:
  python3 scripts/refresh-staged-runtime-metadata.py --tree build/release-v1.1.0/wine \
      --base build/release-v1.1.0/v1.0.5-base/wine \
      --native-manifest build/release-v1.1.0/native-v3/build-manifest.json \
      [--check]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import subprocess
import sys

STAGE_MANIFEST = 'zzz-frame-probe-stage.json'
STAGE_SCHEMA = 3
GRAPHICS_MANIFEST = 'yaagl-wine-p3-graphics-artifacts.json'
PROVENANCE_MANIFEST = 'yaagl-wine-p3-provenance.json'
RUNTIME_MANIFEST = 'yaagl-wine-runtime-files.json'
RUNTIME_TXT = 'yaagl-wine-p3-runtime.txt'
PROJECT_ROOT = pathlib.Path(__file__).resolve().parents[1]
WRITER = PROJECT_ROOT / 'scripts' / 'write-wine-runtime-manifest.py'
PACKAGER = PROJECT_ROOT / 'scripts' / 'package-wine-p3-runtime.sh'

FRAMEWORK_REL = 'lib/external/D3DMetal.framework/Versions/A/D3DMetal'
MODULE_REL = 'lib/external/D3DMetal.framework/Versions/A/Resources/libYaaglNativePsoCache.dylib'
CONVERTER_REL = 'lib/external/D3DMetal.framework/Versions/A/Resources/libmetalirconverter.dylib'
GPTK_SOURCE_SHA256 = 'f8640e6b0974277068821d44bd398dcc0f42cbb730d07f3afad97843e72a6ea3'
CONVERTER_SHA256 = '5c5619ef17a7d62e84db0a7f5181d746623b47364379271fd5827e6bd961ba34'
DEVICE_LIFETIME = {'scope': 'per-native-device', 'retention': 'device-lifetime'}
FRAMEWORK_DEPENDENCY = '@loader_path/Resources/libYaaglNativePsoCache.dylib'
DLSS_MODULE_RELS = ('lib/wine/x86_64-windows/nvngx.dll', 'lib/wine/x86_64-unix/nvngx.so')


def digest(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def tuned_identities() -> list[tuple[str, str, str]]:
    text = PACKAGER.read_text(encoding='utf-8')
    match = re.search(r"TUNED_ARTIFACT_IDENTITIES='(.*?)'\n", text, re.S)
    if not match:
        raise SystemExit('cannot read TUNED_ARTIFACT_IDENTITIES from the packaging script')
    rows = []
    for line in match.group(1).splitlines():
        line = line.strip()
        if not line:
            continue
        path, architecture, artifact_format = line.split('|', 2)
        rows.append((path, architecture, artifact_format))
    if not rows:
        raise SystemExit('TUNED_ARTIFACT_IDENTITIES is empty')
    return rows


def source_fingerprint(sources) -> str:
    accumulator = hashlib.sha256()
    for source in sources:
        accumulator.update(source['path'].encode('utf-8') + b'\0' + source['sha256'].encode('ascii') + b'\n')
    return accumulator.hexdigest()


def system_dependencies(path: pathlib.Path) -> list[str]:
    listing = subprocess.run(['otool', '-arch', 'x86_64', '-l', str(path)],
                             check=True, capture_output=True, text=True).stdout
    names, load = [], False
    for line in listing.splitlines():
        fields = line.split()
        if fields[:1] == ['cmd']:
            load = fields[1:2] == ['LC_LOAD_DYLIB']
            continue
        if load and fields[:1] == ['name']:
            names.append(fields[1])
            load = False
    return names


def read_stage_manifest(tree: pathlib.Path) -> dict:
    path = tree / STAGE_MANIFEST
    if not path.is_file():
        raise SystemExit(f'missing staged-runtime manifest: {path}')
    data = json.loads(path.read_text(encoding='utf-8'))
    if data.get('stage_schema') != STAGE_SCHEMA:
        raise SystemExit(f'unsupported stage schema: {data.get("stage_schema")!r}')
    if data.get('dlss_translation') is not False or data.get('model_policy') != {'all_gpu': 'system-default'}:
        raise SystemExit('staged runtime does not carry the FSR-only system-default policy')
    return data


def assert_tree_untouched(tree: pathlib.Path, stage: dict) -> None:
    """The signed artifacts are the immutable part of the stage record."""
    recorded = stage.get('signed_artifacts')
    if not isinstance(recorded, dict) or not recorded:
        raise SystemExit('stage manifest has no signed_artifacts inventory')
    for relative, expected in recorded.items():
        path = tree / relative
        if not path.is_file():
            raise SystemExit(f'signed artifact is missing from the staged tree: {relative}')
        if digest(path) != expected:
            raise SystemExit(f'signed artifact changed since staging: {relative}')
    for relative in DLSS_MODULE_RELS:
        if (tree / relative).exists() or (tree / relative).is_symlink():
            raise SystemExit(f'DLSS-only module is present in an FSR-only runtime: {relative}')


def refreshed_graphics(tree: pathlib.Path, base: pathlib.Path, native_build: dict, stage: dict) -> dict:
    current = json.loads((base / GRAPHICS_MANIFEST).read_text(encoding='utf-8'))
    artifacts = current['artifacts']
    artifacts['framework'].update({
        'sha256': digest(tree / FRAMEWORK_REL),
        'preSignSha256': stage['d3dmetal_input']['sha256'],
        'inputKind': stage['d3dmetal_input']['kind'],
        'sourceSha256': GPTK_SOURCE_SHA256,
    })
    artifacts['module'].update({
        'sha256': digest(tree / MODULE_REL),
        'preSignSha256': native_build['module']['sha256'],
        'sourceFingerprintSha256': source_fingerprint(native_build['sources']),
        'systemDependencies': system_dependencies(tree / MODULE_REL),
    })
    artifacts['converter'].update({
        'sha256': digest(tree / CONVERTER_REL),
        'sourceSha256': CONVERTER_SHA256,
    })
    payload = dict(current)
    payload.update({
        'schemaVersion': 3,
        'cache': dict(DEVICE_LIFETIME),
        'functionCache': dict(DEVICE_LIFETIME),
        'frameworkDependency': FRAMEWORK_DEPENDENCY,
        'nativePsoCacheBuild': native_build,
        'artifacts': artifacts,
    })
    return payload


def refreshed_provenance(tree: pathlib.Path, base: pathlib.Path, graphics: dict, stage: dict,
                         identities, native_build: dict) -> dict:
    payload = json.loads((base / PROVENANCE_MANIFEST).read_text(encoding='utf-8'))

    authenticated = []
    for relative in ('bin/wine', 'bin/wine.real', 'bin/wineserver'):
        path = tree / relative
        authenticated.append({'path': relative, 'size': path.stat().st_size, 'sha256': digest(path)})
    payload['authenticatedArtifacts'] = authenticated

    payload['artifactHashSemantics'] = {
        'rebuiltArtifacts': 'SHA-256 of host/build bytes before package rewriting and signing',
        'packagedArtifacts': 'SHA-256 of final packaged bytes after all package rewriting and signing',
    }
    packaged = []
    for relative, architecture, artifact_format in identities:
        packaged.append({'path': relative, 'architecture': architecture, 'format': artifact_format,
                         'sha256': digest(tree / relative)})
    payload['packagedArtifacts'] = packaged
    payload['finalGraphicsArtifacts'] = graphics

    fsr_artifacts = []
    for relative in sorted(stage['signed_artifacts']):
        if 'amd_fidelityfx' in relative:
            fsr_artifacts.append({'path': relative, 'sha256': stage['signed_artifacts'][relative]})
    inherited = 0
    changed = []
    for relative, _, _ in identities:
        if digest(tree / relative) == digest(base / relative):
            inherited += 1
        else:
            changed.append(relative)
    payload['v11RuntimeOverlay'] = {
        'baseRuntime': str(base),
        'stageSchema': STAGE_SCHEMA,
        'stageManifest': STAGE_MANIFEST,
        'stageManifestSha256': digest(tree / STAGE_MANIFEST),
        'dlssTranslation': False,
        'modelPolicy': dict(stage['model_policy']),
        'fsrTranslatorPolicy': dict(stage['fsr_translator']),
        'd3dmetalInput': dict(stage['d3dmetal_input']),
        'nativeFrameGenerationFallback': dict(stage['native_fg_fallback']),
        'fsrBuildManifest': stage['fsr_build_manifest'],
        'nativeBuildManifest': native_build,
        'fsrArtifacts': fsr_artifacts,
        'inheritedCoreArtifacts': inherited,
        'changedCoreArtifacts': changed,
        'removedDlssModules': list(DLSS_MODULE_RELS),
    }
    return payload


def refreshed_runtime_txt(tree: pathlib.Path, graphics: dict) -> str:
    path = tree / RUNTIME_TXT
    lines = path.read_text(encoding='utf-8').splitlines()
    while lines and lines[-1].startswith(('D3DMetal signed artifact SHA-256:', 'Native PSO cache signed artifact SHA-256:')):
        lines.pop()
    lines.append(f'D3DMetal signed artifact SHA-256: {graphics["artifacts"]["framework"]["sha256"]}')
    lines.append(f'Native PSO cache signed artifact SHA-256: {graphics["artifacts"]["module"]["sha256"]}')
    return '\n'.join(lines) + '\n'


def write_json(path: pathlib.Path, payload: dict) -> None:
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + '\n', encoding='utf-8')


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tree', type=pathlib.Path, default=pathlib.Path('build/release-v1.1.0/wine'))
    parser.add_argument('--base', type=pathlib.Path, default=pathlib.Path('build/release-v1.1.0/v1.0.5-base/wine'))
    parser.add_argument('--native-manifest', type=pathlib.Path,
                        default=pathlib.Path('build/release-v1.1.0/native-v3/build-manifest.json'))
    parser.add_argument('--check', action='store_true', help='verify without writing')
    args = parser.parse_args()

    tree = args.tree.resolve()
    base = args.base.resolve()
    if not tree.is_dir() or not base.is_dir():
        raise SystemExit('both --tree and --base must exist')
    native_build = json.loads(args.native_manifest.resolve().read_text(encoding='utf-8'))
    stage = read_stage_manifest(tree)
    assert_tree_untouched(tree, stage)
    identities = tuned_identities()

    graphics = refreshed_graphics(tree, base, native_build, stage)
    provenance = refreshed_provenance(tree, base, graphics, stage, identities, native_build)
    runtime_txt = refreshed_runtime_txt(tree, graphics)

    if args.check:
        print('CHECK: signed artifacts match the stage record; metadata refresh is safe to write')
        return 0

    write_json(tree / GRAPHICS_MANIFEST, graphics)
    write_json(tree / PROVENANCE_MANIFEST, provenance)
    (tree / RUNTIME_TXT).write_text(runtime_txt, encoding='utf-8')
    subprocess.run([sys.executable, str(WRITER), str(tree),
                    provenance['runtimeId'], provenance['wineVersion']], check=True)
    assert_tree_untouched(tree, stage)
    print(f'REFRESHED: {tree}')
    print(f'  framework {graphics["artifacts"]["framework"]["sha256"]}')
    print(f'  module    {graphics["artifacts"]["module"]["sha256"]}')
    print(f'  packaged artifacts {len(provenance["packagedArtifacts"])}; inherited core {provenance["v11RuntimeOverlay"]["inheritedCoreArtifacts"]}')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        sys.exit(f'refresh-metadata: {error}')
