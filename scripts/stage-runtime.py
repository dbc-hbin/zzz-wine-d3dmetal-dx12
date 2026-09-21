#!/usr/bin/env python3
"""Stage a PRIVATE Wine copy with MetalFX fixes or frame diagnostics. Never edit the installed runtime or game."""
from __future__ import annotations
import argparse, hashlib, json, os, platform, re, shlex, shutil, subprocess, sys, uuid
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
REL=Path('lib/external/D3DMetal.framework/Versions/A')
HELPER_NAME='yaagl-frame-probe-exec'
HELPER_MARKER='$wrapper_dir/'+HELPER_NAME
PLAIN_EXEC='exec "$real_wine" "$@"'
PROBE_EXEC='exec "'+HELPER_MARKER+'" "$real_wine" "$@"'
STAGE_MANIFEST='zzz-frame-probe-stage.json'
# Diagnostic contract shared with d3dmetal-pso-cache/frame-probe.mm: the helper
# environment and the recorded stage manifest are rendered from these constants,
# so the runtime manifest cannot advertise a policy the helper does not export.
STAGE_SCHEMA=2
DIAGNOSTIC_VERSION=3
CAPTURE_PROFILE='capture'
PLAY_PROFILE='play'
COMPOSITION_ENV='YAAGL_METALFX_COMPOSITION_TRACE'
FSR_OVERRIDE='amd_fidelityfx_upscaler_dx12,amd_fidelityfx_framegeneration_dx12=b'
ORIGINAL_FG_SOURCE=Path('/Applications/Zenless Zone Zero/amd_fidelityfx_framegeneration_dx12.dll')
ORIGINAL_FG_SHA256='3f5e674a59b400756e98ef31fd583a4eb08ad567ec8dee362886bc96e55ed347'
ORIGINAL_FG_EXPORTS=((1,'ffxConfigure'),(2,'ffxCreateContext'),(3,'ffxDestroyContext'),(4,'ffxDispatch'),(5,'ffxQuery'))
PRIVATE_FG_PATH='lib/wine/x86_64-windows/amd_fidelityfx_framegeneration_dx12_native.dll'
FSR_ARTIFACT_PATHS=('lib/wine/x86_64-windows/amd_fidelityfx_upscaler_dx12.dll','lib/wine/x86_64-unix/amd_fidelityfx_upscaler_dx12.so','lib/wine/x86_64-windows/amd_fidelityfx_framegeneration_dx12.dll','lib/wine/x86_64-unix/amd_fidelityfx_framegeneration_dx12.so',PRIVATE_FG_PATH)
FSR_POLICY={'implementation':'builtin-fsr-api-to-metalfx-with-metalfx-frame-interpolation','dll_override':FSR_OVERRIDE,'native_fg_fallback':PRIVATE_FG_PATH,'loader_override':False,'metal_hud':'1','diagnostic_log_environment':'YAAGL_FSR_LOG'}
PROFILES=(CAPTURE_PROFILE,PLAY_PROFILE)
ENVIRONMENT_ORDER=('MTL_CAPTURE_ENABLED','YAAGL_METALFX_FRAME_PROBE','YAAGL_METALFX_DIAGNOSTICS')
PROBE_ENVIRONMENT={'MTL_CAPTURE_ENABLED':'1','YAAGL_METALFX_FRAME_PROBE':'1','YAAGL_METALFX_DIAGNOSTICS':'0'}
PLAY_ENVIRONMENT={name:'0' for name in ENVIRONMENT_ORDER}
# A play copy preserves game sizing and leaves temporal-model selection to the
# system on every GPU. The previous ordering experiment remains opt-in.
PLAY_POLICY_VERSION=4
PLAY_RENDER_DEFAULTS={'YAAGL_METALFX_ORDERING':'0'}
PLAY_MODEL_POLICY={'all_gpu':'system-default'}
RETIRED_RENDER_ENV='YAAGL_METALFX_RENDER_PRESET'
PROBE_UNSET=('YAAGL_METALFX_MODEL','YAAGL_METALFX_TEMPORAL','YAAGL_METALFX_TEMPORAL_TESTS')
HISTORICAL_PROBE_UNSET=('YAAGL_METALFX_TEMPORAL','YAAGL_METALFX_TEMPORAL_TESTS')
# Build manifests identify the unsigned module; also identify the signed files
# actually launched, so accidentally copying an older sidecar is detectable.
ARTIFACT_PATHS=('bin/wine','bin/wine.real','bin/'+HELPER_NAME,
    str(REL/'D3DMetal'),str(REL/'Resources/libYaaglNativePsoCache.dylib'),
    str(REL/'Resources/libmetalirconverter.dylib'),
    'lib/wine/x86_64-windows/d3d12.dll','lib/wine/x86_64-unix/d3d12.so',
    'lib/wine/x86_64-windows/nvngx.dll','lib/wine/x86_64-unix/nvngx.so')
# Any number of helper hops (including a doubly wrapped copy) collapses to the
# single plain hop, so staging a runtime that is already helper-routed neither
# nests the helper nor rejects the source.
HELPER_HOPS=re.compile(r'exec\s+(?:(?:exec\s+)?"'+re.escape(HELPER_MARKER)+r'"\s+)+')

def run(args:list[str]) -> None:
    print('+',shlex.join(args),flush=True);subprocess.run(args,check=True)

def under(path:Path,root:Path) -> bool:
    try:path.resolve().relative_to(root.resolve());return True
    except ValueError:return False

def artifact_hashes(runtime:Path,paths=ARTIFACT_PATHS) -> dict[str,str]:
    result={}
    for relative in paths:
        path=runtime/relative
        if not under(path,runtime):raise ValueError(f'external runtime artifact: {relative}')
        result[relative]=hashlib.sha256(path.read_bytes()).hexdigest()
    return result

def original_fg_provenance(path:Path) -> dict:
    if not path.is_file():raise ValueError(f'missing original frame-generation fallback: {path}')
    digest=hashlib.sha256(path.read_bytes()).hexdigest()
    if digest!=ORIGINAL_FG_SHA256:
        raise ValueError(f'original frame-generation SHA mismatch: expected {ORIGINAL_FG_SHA256}, got {digest}')
    readobj=Path('/opt/llvm-mingw-20260616-ucrt-macos-universal/bin/llvm-readobj')
    if not readobj.is_file():raise ValueError(f'missing PE inspection tool: {readobj}')
    output=subprocess.check_output([str(readobj),'--coff-exports',str(path)],text=True)
    if 'Format: COFF-x86-64' not in output:raise ValueError('original frame-generation fallback is not x86_64 PE')
    exports=tuple((int(ordinal),name) for ordinal,name in re.findall(
        r'Ordinal: (\d+)\s+Name: (\w+)',output))
    if exports!=ORIGINAL_FG_EXPORTS:raise ValueError(f'original frame-generation exports mismatch: {exports!r}')
    return {'source':str(path),'runtime_path':PRIVATE_FG_PATH,'sha256':digest,
        'size':path.stat().st_size,'architecture':'COFF-x86-64',
        'exports':[{'ordinal':ordinal,'name':name} for ordinal,name in exports],
        'source_access':'read-only','loader_override':False}

def artifact_problems(runtime:Path,recorded) -> list[str]:
    if not isinstance(recorded,dict):
        return ['signed artifact inventory is missing or incomplete; restage with current tooling']
    paths=tuple(recorded)
    if set(paths) not in (set(ARTIFACT_PATHS),set(ARTIFACT_PATHS+FSR_ARTIFACT_PATHS)):
        return ['signed artifact inventory is missing or incomplete; restage with current tooling']
    try:actual=artifact_hashes(runtime,paths)
    except (OSError,ValueError) as error:return [str(error)]
    return [f'signed runtime artifact changed: {name}' for name in paths
        if recorded[name]!=actual[name]]

def verify_runtime(runtime:Path,current_sources:bool=False) -> list[tuple[str,str]]:
    report=stage_manifest_report(runtime)
    data=json.loads((runtime/STAGE_MANIFEST).read_text())
    problems=artifact_problems(runtime,data.get('signed_artifacts'))
    if current_sources:
        manifests=[('native',data.get('native_build_manifest'))]
        if data.get('fsr_translator') is not None:
            manifests.append(('FSR translator',data.get('fsr_build_manifest')))
        for label,build_manifest in manifests:
            sources=build_manifest.get('sources') if isinstance(build_manifest,dict) else None
            if not isinstance(sources,list) or not sources:
                problems.append(f'{label} build source inventory is missing')
                continue
            for source in sources:
                path=ROOT/source['path']
                if not under(path,ROOT) or not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest()!=source['sha256']:
                    problems.append(f'build source changed: {source["path"]}')
    if problems:report += [('FAIL',message) for message in problems]
    else:report.append(('PASS','signed launch artifacts'+(' and current native sources' if current_sources else '')+' match their manifest'))
    return report

def normalize_wrapper(text:str) -> str:
    if not text.startswith('#!'):raise ValueError('unrecognized Wine shell wrapper: missing the interpreter line')
    normalized=HELPER_HOPS.sub('exec ',text)
    if PLAIN_EXEC not in normalized:
        raise ValueError('unrecognized Wine shell wrapper: no "exec \\"$real_wine\\" \\"$@\\"" launch hop to rewrite')
    return normalized

def helper_hops(text:str) -> int:
    return text.count('exec "'+HELPER_MARKER+'"')

def profile_environment(profile:str) -> dict:
    if profile not in PROFILES:raise ValueError(f'unknown staging profile {profile!r}')
    return {CAPTURE_PROFILE:PROBE_ENVIRONMENT,PLAY_PROFILE:PLAY_ENVIRONMENT}[profile]

CORE_ENVIRONMENT=ENVIRONMENT_ORDER

def environment_problems(recorded, profile:str) -> list[str]:
    if not isinstance(recorded,dict):return ['missing probe_environment']
    expected=profile_environment(profile);problems=[]
    for name,value in recorded.items():
        if name not in CORE_ENVIRONMENT:problems.append(f'recorded probe environment contains unknown variable: {name}')
        elif expected.get(name)!=value:problems.append(f'recorded probe environment sets {name}={value!r}, expected {expected.get(name)!r}')
    missing=sorted(set(CORE_ENVIRONMENT)-set(recorded))
    if missing:problems.append('recorded probe environment omits required variables: '+', '.join(missing))
    return problems

def helper_script(probe:Path, profile:str=CAPTURE_PROFILE, *, composition:bool=False, fsr_translator:bool=False) -> str:
    environment=profile_environment(profile)
    lines=['#!/bin/sh','set -eu']
    if fsr_translator:
        lines+=['export WINEDLLOVERRIDES='+FSR_OVERRIDE,'export MTL_HUD_ENABLED=1','runtime_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)',f'export YAAGL_FSR_FG_NATIVE_DLL="Z:$runtime_root/{PRIVATE_FG_PATH}"']
    lines.append(f'export {COMPOSITION_ENV}={int(composition)}')
    lines+=[f'export {name}={environment[name]}' for name in ENVIRONMENT_ORDER]
    lines.append('unset '+' '.join(PROBE_UNSET))
    lines.append('export YAAGL_METALFX_PROBE_DIR=${YAAGL_METALFX_PROBE_DIR:-'+shlex.quote(str(probe))+'}')
    if profile==PLAY_PROFILE:
        lines+=['# Preserve the game render size and use the system-default temporal model.','unset '+RETIRED_RENDER_ENV]
        lines+=[f'export {name}=${{{name}:-{value}}}' for name,value in PLAY_RENDER_DEFAULTS.items()]
    lines.append('exec "$@"')
    return '\n'.join(lines)+'\n'

def helper_problems(text:str, probe:Path, profile:str=CAPTURE_PROFILE, names=ENVIRONMENT_ORDER,
        render_defaults=None, play_policy_version=PLAY_POLICY_VERSION) -> list[str]:
    problems=[];environment=profile_environment(profile)
    for name in names:
        if name not in ENVIRONMENT_ORDER:
            problems.append(f'helper validation asked about an unknown variable: {name}');continue
        expected=f'export {name}={environment[name]}'
        if expected+'\n' not in text:problems.append(f'helper does not render "{expected}"')
    expected_unset=HISTORICAL_PROBE_UNSET if profile==PLAY_PROFILE and play_policy_version<PLAY_POLICY_VERSION else PROBE_UNSET
    if 'unset '+' '.join(expected_unset)+'\n' not in text:problems.append('helper does not unset the retired model/temporal variables')
    if shlex.quote(str(probe)) not in text:problems.append('helper does not default the probe directory to the staged path')
    execs=[line for line in text.splitlines() if line.startswith('exec ')]
    if execs!=['exec "$@"']:problems.append('helper must end with exactly one nested-free exec hop')
    if profile==PLAY_PROFILE:
        for name,value in (PLAY_RENDER_DEFAULTS if render_defaults is None else render_defaults).items():
            if f'export {name}=${{{name}:-{value}}}\n' not in text:
                problems.append(f'play helper does not render the {name} default')
        if play_policy_version>=2:
            if 'unset '+RETIRED_RENDER_ENV+'\n' not in text:problems.append('play helper does not clear the retired sizing override')
            if re.search(r'^export\s+'+RETIRED_RENDER_ENV+r'=',text,re.M):problems.append('play helper still exports the retired sizing override')
    return problems

def stage_manifest_report(source:Path,allow_historical_diagnostics:bool=False) -> list[tuple[str,str]]:
    """Verdicts for an already staged source; FAIL blocks repeat staging."""
    path=source/STAGE_MANIFEST
    helper=source/'bin'/HELPER_NAME
    if not path.exists():
        return [('INFO','no stage manifest in the source: not a previously staged diagnostic runtime')]
    try:data=json.loads(path.read_text())
    except json.JSONDecodeError:return [('FAIL',f'{STAGE_MANIFEST} is not valid JSON; restage from an intact runtime')]
    schema=data.get('stage_schema')
    if not isinstance(schema,int) or schema<STAGE_SCHEMA:
        return [('INFO',f'staged diagnostic runtime reports stage_schema {schema!r}; restaging upgrades it to {STAGE_SCHEMA}')]
    if schema>STAGE_SCHEMA:
        return [('FAIL',f'source was staged with stage_schema {schema}, newer than {STAGE_SCHEMA}: restage with matching tooling')]
    profile=data.get('profile',CAPTURE_PROFILE)
    if profile not in PROFILES:
        return [('FAIL',f'staged manifest records unknown profile {profile!r}; restage with this tooling')]
    problems=[]
    historical_diagnostics=allow_historical_diagnostics and data.get('diagnostic_version')==2
    if data.get('diagnostic_version')!=DIAGNOSTIC_VERSION and not historical_diagnostics:
        problems.append(f'diagnostic_version is {data.get("diagnostic_version")!r}, expected {DIAGNOSTIC_VERSION}')
    composition=data.get('composition_trace')
    if composition is not None:
        if not isinstance(composition,bool) or (composition and profile!=CAPTURE_PROFILE):
            problems.append('composition trace is only valid in the capture profile')
        elif helper.exists() and f'export {COMPOSITION_ENV}={int(composition)}\n' not in helper.read_text():
            problems.append('composition trace manifest does not match the helper')
    fsr=data.get('fsr_translator')
    if fsr is not None:
        if fsr!=FSR_POLICY:problems.append('unsupported FSR translator launch policy')
        fallback=data.get('native_fg_fallback')
        expected_exports=[{'ordinal':ordinal,'name':name} for ordinal,name in ORIGINAL_FG_EXPORTS]
        if (not isinstance(fallback,dict) or fallback.get('runtime_path')!=PRIVATE_FG_PATH or
                fallback.get('sha256')!=ORIGINAL_FG_SHA256 or fallback.get('architecture')!='COFF-x86-64' or
                fallback.get('exports')!=expected_exports or fallback.get('loader_override') is not False):
            problems.append('native frame-generation fallback provenance is missing or invalid')
        private_fallback=source/PRIVATE_FG_PATH
        if not private_fallback.is_file() or private_fallback.stat().st_mode&0o222:
            problems.append('renamed native frame-generation fallback is missing or writable')
        if data.get('rendering_changes_by_default') is not True:
            problems.append('FSR translation must be recorded as a rendering implementation change')
        if helper.exists():
            text=helper.read_text()
            if (f'export WINEDLLOVERRIDES={FSR_OVERRIDE}\n' not in text or
                    'export MTL_HUD_ENABLED=1\n' not in text):
                problems.append('FSR translator manifest does not match the last-hop helper')
    d3dmetal_input=data.get('d3dmetal_input')
    if d3dmetal_input is not None:
        if (not isinstance(d3dmetal_input,dict) or d3dmetal_input.get('kind') not in ('pristine','patched') or
                not re.fullmatch(r'[0-9a-f]{64}|fixture|test|f864',str(d3dmetal_input.get('sha256','')))):
            problems.append('recorded D3DMetal input kind or SHA is invalid')
        elif d3dmetal_input['kind']=='patched' and 'pristine_sha256' in data:
            problems.append('patched D3DMetal input is falsely labeled pristine')
    recorded_environment=data.get('probe_environment')
    problems+=environment_problems(recorded_environment,profile)
    play_policy=data.get('render_policy_version',1)
    expected_unset=list(HISTORICAL_PROBE_UNSET) if profile==PLAY_PROFILE and play_policy<PLAY_POLICY_VERSION else list(PROBE_UNSET)
    if data.get('probe_unset')!=expected_unset:problems.append('recorded unset variables do not match this tooling')
    render_defaults=PLAY_RENDER_DEFAULTS
    if profile==PLAY_PROFILE:
        if play_policy==1:
            # Validate an old source against its historical helper contract,
            # then replace it with the current policy when creating the copy.
            render_defaults={RETIRED_RENDER_ENV:'quality',
                'YAAGL_METALFX_ORDERING':'1','YAAGL_METALFX_MODEL':'default'}
        elif play_policy!=PLAY_POLICY_VERSION:
            problems.append('unsupported play rendering policy version')
        if play_policy==PLAY_POLICY_VERSION and data.get('model_policy')!=PLAY_MODEL_POLICY:
            problems.append('recorded play model policy does not match its policy version')
        if data.get('render_environment_defaults')!=render_defaults:
            problems.append('recorded play defaults do not match their policy version')
    if 'signed_artifacts' in data:
        problems+=artifact_problems(source,data['signed_artifacts'])
    if not helper.exists():problems.append(f'stage schema {schema} requires bin/{HELPER_NAME}')
    else:
        claimed=tuple(name for name in ENVIRONMENT_ORDER if isinstance(recorded_environment,dict) and name in recorded_environment)
        problems+=helper_problems(helper.read_text(),Path(str(data.get('probe_dir',''))),profile,
            claimed or ENVIRONMENT_ORDER,render_defaults,play_policy)
    if problems:return [('FAIL','staged manifest/helper is inconsistent: '+'; '.join(problems))]
    report=[('PASS',f'staged manifest {profile} policy matches the last-hop helper')]
    if historical_diagnostics:
        report.append(('INFO','diagnostic version 2 accepted as a staging source; the new copy rebuilds version 3 with reserved capture log space'))
    if profile==PLAY_PROFILE and play_policy<PLAY_POLICY_VERSION:
        report.append(('INFO','historical play policy accepted as source; fresh copy upgrades sizing and model policy metadata'))
    if data.get('rendering_changes_by_default') is False or data.get('diagnostic_only') is True:
        report.append(('INFO','the source manifest records diagnostic_only=%r / rendering_changes_by_default=%r as its own '
            'historical policy; restaging is allowed, and the new copy records its selected profile independently.'
            %(data.get('diagnostic_only'),data.get('rendering_changes_by_default'))))
    return report

def stage_manifest(profile:str,*,source:Path,probe:Path,pristine_sha256:str,inspection:dict,native_manifest:dict,
        identity:dict,source_launcher:dict,helper_text:str,signed_artifacts:dict|None=None,composition:bool=False,
        fsr_translator:bool=False, fsr_build_manifest:dict|None=None,
        native_fg_fallback:dict|None=None,d3dmetal_input_kind:str='pristine') -> dict:
    """Record this profile's own defaults; source claims remain historical.
    Every GPU uses the system-default temporal model. Play disables diagnostics.
    """
    manifest={'stage_schema':STAGE_SCHEMA,'diagnostic_version':DIAGNOSTIC_VERSION,'diagnostic_only':False,
        'rendering_changes_by_default':False,'profile':profile,'source_runtime':str(source),
        'probe_dir':str(probe),'binary_inspection':inspection,'native_build_manifest':native_manifest,
        'probe_environment':profile_environment(profile),
        'probe_unset':list(PROBE_UNSET),'source_launcher':source_launcher,
        'launcher_helper':{'path':'bin/'+HELPER_NAME,'game_launch_only':profile==CAPTURE_PROFILE,
            'nested_hops':helper_hops(helper_text)},
        'old_temporal_repair_disabled':True,
        'd3dmetal_input':{'kind':d3dmetal_input_kind,'sha256':pristine_sha256}}
    if d3dmetal_input_kind=='pristine':manifest['pristine_sha256']=pristine_sha256
    manifest['baseline_scope']='pinned-pre-pso-framework; earlier compatibility fixes and Wine/converter retained'
    manifest['composition_trace']=composition
    manifest['resource_contract_repairs']={
        'metalfx_output_storage':'private shadow for Shared output, original texture restored by ordered GPU copies',
        'pixel_conversion':False,'cpu_wait':False,'model_override':False}
    if signed_artifacts is not None:manifest['signed_artifacts']=signed_artifacts
    if profile==PLAY_PROFILE:
        manifest['rendering_changes_by_default']=False
        manifest['render_environment_defaults']=PLAY_RENDER_DEFAULTS.copy()
        manifest['render_policy_version']=PLAY_POLICY_VERSION
        manifest['render_size_override']=False
        manifest['model_policy']=PLAY_MODEL_POLICY.copy()
    if identity:
        manifest['source_identity']=identity
        manifest['source_identity_note']=('historical evidence recorded by the staging source; '
            'this copy records its own rendering defaults separately')
    if fsr_translator:
        manifest['fsr_translator']=FSR_POLICY.copy()
        manifest['fsr_build_manifest']=fsr_build_manifest
        manifest['native_fg_fallback']=native_fg_fallback
        manifest['rendering_changes_by_default']=True
        manifest['resource_contract_repairs']={
            'metalfx_output_storage':'private shadow only when required; copy the evaluated output rectangle',
            'pixel_conversion':'numeric exposure R-channel to R16Float only when required',
            'cpu_wait':False,'model_override':False}
    return manifest

def source_identity(source:Path) -> dict:
    """Identity flags an already staged source recorded, kept only as historical evidence."""
    try:data=json.loads((source/STAGE_MANIFEST).read_text())
    except (OSError,json.JSONDecodeError):return {}
    if not isinstance(data,dict):return {}
    return {key:data[key] for key in ('diagnostic_only','rendering_changes_by_default') if isinstance(data.get(key),bool)}

def main() -> int:
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--wine-source',type=Path)
    p.add_argument('--wine-dest',type=Path)
    d3dmetal=p.add_mutually_exclusive_group()
    d3dmetal.add_argument('--pristine-d3dmetal',type=Path,help='pinned pre-PSO f864 framework, not an unmodified Apple binary')
    d3dmetal.add_argument('--patched-d3dmetal',type=Path,help='strictly verified patched or patched-signed f864 framework binary')
    p.add_argument('--verify-runtime',type=Path,help='verify a previously published copy without modifying it')
    p.add_argument('--current-sources',action='store_true',help='also compare native build source hashes during verification')
    p.add_argument('--probe-dir',type=Path,help='required for diagnostics; optional for --play')
    p.add_argument('--build-dir',type=Path,default=ROOT/'build/frame-probe-stage')
    p.add_argument('--original-fg',type=Path,default=ORIGINAL_FG_SOURCE,
        help='read-only installed original frame-generation DLL copied under the pinned private fallback basename')
    p.add_argument('--composition',action='store_true',help='record Metal4 downstream draw/binding/queue metadata during native captures')
    p.add_argument('--fsr-translator',action='store_true',
        help='stage the builtin FidelityFX upscaler DLL and force FSR API translation to MetalFX')
    profiles=p.add_mutually_exclusive_group()
    profiles.add_argument('--play',action='store_true',
        help='stage an ordinary launch copy with diagnostics off and unchanged game sizing; '
            'all GPUs use the system-default temporal model')
    p.add_argument('--check',action='store_true')
    a=p.parse_args()
    if a.verify_runtime:
        if (a.wine_source or a.wine_dest or a.pristine_d3dmetal or a.patched_d3dmetal or
                a.check or a.fsr_translator):
            p.error('--verify-runtime cannot be combined with staging arguments')
        report=verify_runtime(a.verify_runtime.expanduser().resolve(),a.current_sources)
        for level,message in report:print(f'{level}: {message}')
        return int(any(level=='FAIL' for level,_ in report))
    if not a.wine_source or not a.wine_dest or not (a.pristine_d3dmetal or a.patched_d3dmetal):
        p.error('staging requires --wine-source, --wine-dest and exactly one D3DMetal input')
    if a.current_sources:p.error('--current-sources requires --verify-runtime')
    if a.fsr_translator and not a.play:p.error('--fsr-translator requires --play')
    profile=PLAY_PROFILE if a.play else CAPTURE_PROFILE
    source=a.wine_source.expanduser().resolve();dest=a.wine_dest.expanduser().absolute()
    original_fg=a.original_fg.expanduser().resolve()
    d3dmetal_input=(a.patched_d3dmetal or a.pristine_d3dmetal).expanduser().resolve()
    d3dmetal_input_kind='patched' if a.patched_d3dmetal else 'pristine'
    build=a.build_dir.expanduser().absolute()
    if a.composition and profile!=CAPTURE_PROFILE:p.error('--composition requires the capture profile; omit --play')
    if not a.probe_dir and profile!=PLAY_PROFILE:p.error('--probe-dir is required for the capture profile')
    probe=a.probe_dir.expanduser().absolute() if a.probe_dir else build/'diagnostics-off'
    if dest.exists() or dest.is_symlink():p.error('wine-dest must not already exist')
    if under(dest,source) or under(source,dest):p.error('source and destination must not contain one another')
    if not (source/'bin/wine').is_file() or not (source/REL/'D3DMetal').is_file():p.error('expected the prior ZZZ runtime layout with bin/wine and lib/external/D3DMetal.framework')
    wrapper=(source/'bin/wine').read_text()
    try:normalized=normalize_wrapper(wrapper)
    except ValueError as error:p.error(str(error))
    hops=helper_hops(wrapper)
    source_report=[('PASS','source runtime layout and launcher wrapper recognized'),
        ('PASS',f'launcher wrapper is {"already helper-routed; repeat staging stays single-layer" if hops else "plain; staging adds one helper hop"}')]
    stage_report=stage_manifest_report(source,allow_historical_diagnostics=True)
    failed=[message for level,message in stage_report if level=='FAIL']
    if a.check:
        for level,message in source_report+stage_report:print(f'{level}: {message}')
    if failed:p.error('; '.join(failed))
    actual=hashlib.sha256(d3dmetal_input.read_bytes()).hexdigest()
    checker=ROOT/'scripts/d3dmetal-pso-cache-patch.mjs'
    if d3dmetal_input_kind=='pristine':
        expected=json.loads((ROOT/'d3dmetal-pso-cache/layout.json').read_text())['source']['sha256']
        if actual!=expected:p.error(f'pristine D3DMetal SHA mismatch: expected {expected}, got {actual}. Do not supply the already-patched binary.')
        input_inspection=None
    else:
        try:input_inspection=json.loads(subprocess.check_output(
            ['node',str(checker),'inspect',str(d3dmetal_input)],text=True))
        except (subprocess.CalledProcessError,json.JSONDecodeError) as error:
            p.error(f'patched D3DMetal inspection failed: {error}')
        if input_inspection.get('mode') not in ('patched','patched-signed'):
            p.error('patched D3DMetal must pass the pinned f864 layout and payload inspection')
    fg_provenance=original_fg_provenance(original_fg) if a.fsr_translator else None
    if probe.exists():
        st=probe.lstat()
        if probe.is_symlink() or not probe.is_dir() or st.st_uid!=os.geteuid() or st.st_mode&0o077:p.error('probe-dir must be owned by you, mode 0700, not a symlink')
    if a.check:
        print(f'PASS: destination is isolated and the {d3dmetal_input_kind} D3DMetal identity matches the pinned f864 layout')
        print(f'PASS: repeat staging is supported; this run would publish stage_schema {STAGE_SCHEMA} with profile {profile}.')
        if a.fsr_translator:
            print('PASS: builtin upscaler and frame-generation translators would be staged after the wrapper reset; the loader remains unchanged.')
            print(f'PASS: pinned original frame-generation fallback {fg_provenance["sha256"]} would be copied read-only as {PRIVATE_FG_PATH}.')
        if profile==PLAY_PROFILE:
            print('PASS: play profile disables diagnostics, preserves game sizing, and uses the system-default temporal model on all GPUs.')
        inherited=source_identity(source)
        if inherited:
            print(f'INFO: the staging source records {inherited} as its own historical policy; '
                'this copy records diagnostic_only=False / rendering_changes_by_default=False.')
        print('No changes.')
        return 0
    if platform.system()!='Darwin':p.error('staging requires macOS, full Xcode, Node.js and codesign')
    dest.parent.mkdir(parents=True,exist_ok=True)
    if profile!=PLAY_PROFILE:probe.mkdir(parents=True,exist_ok=True,mode=0o700)
    build.mkdir(parents=True,exist_ok=True)
    run(['node',str(ROOT/'scripts/build-d3dmetal-pso-cache.mjs'),str(build)])
    fsr_build=build/'fsr-translator'
    if a.fsr_translator:
        run([str(ROOT/'scripts/build-fsr-translator.sh'),str(fsr_build)])
    temporary=dest.parent/(dest.name+'.staging-'+uuid.uuid4().hex)
    try:
        run(['ditto',str(source),str(temporary)])
        binary=temporary/REL/'D3DMetal';module=temporary/REL/'Resources/libYaaglNativePsoCache.dylib'
        for path in (binary,module,temporary/'bin/wine'):
            if not under(path,temporary):raise RuntimeError(f'copied runtime contains an external replacement symlink: {path}')
        patched=build/'D3DMetal.frame-probe'
        if d3dmetal_input_kind=='pristine':
            run(['node',str(checker),'patch',str(d3dmetal_input),str(patched)])
            shutil.copy2(patched,binary)
        else:
            shutil.copy2(d3dmetal_input,binary)
        module.parent.mkdir(parents=True,exist_ok=True)
        built=build/'libYaaglNativePsoCache.dylib'
        module_bytes=built.read_bytes()
        if a.composition and COMPOSITION_ENV.encode() not in module_bytes:
            raise RuntimeError('built native module does not implement composition tracing')
        shutil.copy2(built,module)
        if a.fsr_translator:
            for relative in FSR_ARTIFACT_PATHS[:-1]:
                target=temporary/relative
                target.parent.mkdir(parents=True,exist_ok=True)
                shutil.copy2(fsr_build/relative,target)
            fallback=temporary/PRIVATE_FG_PATH
            fallback.parent.mkdir(parents=True,exist_ok=True)
            shutil.copy2(original_fg,fallback)
            fallback.chmod(0o444)
            copied_provenance=original_fg_provenance(fallback)
            if copied_provenance['sha256']!=fg_provenance['sha256']:
                raise RuntimeError('copied native frame-generation fallback changed during staging')
            run(['codesign','--force','--sign','-',str(temporary/FSR_ARTIFACT_PATHS[1])])
            run(['codesign','--force','--sign','-',str(temporary/FSR_ARTIFACT_PATHS[3])])
        run(['codesign','--force','--sign','-',str(module)])
        run(['codesign','--force','--sign','-',str(temporary/'lib/external/D3DMetal.framework')])
        run(['codesign','--verify','--verbose',str(temporary/'lib/external/D3DMetal.framework')])
        checker=ROOT/'scripts/d3dmetal-pso-cache-patch.mjs'
        result=subprocess.check_output(['node',str(checker),'inspect',str(binary)],text=True)
        inspection=json.loads(result)
        if inspection.get('mode') not in ('patched','patched-signed'):raise RuntimeError('post-signature D3DMetal byte-span validation failed')
        helper=temporary/'bin'/HELPER_NAME
        rendered=helper_script(probe,profile,composition=a.composition,fsr_translator=a.fsr_translator)
        problems=helper_problems(rendered,probe,profile)
        if problems:raise RuntimeError('refusing to publish a helper that contradicts the manifest: '+'; '.join(problems))
        helper.write_text(rendered);helper.chmod(0o755)
        (temporary/'bin/wine').write_text(normalized.replace(PLAIN_EXEC,PROBE_EXEC))
        manifest=stage_manifest(profile,source=source,probe=probe,pristine_sha256=actual,inspection=inspection,
            native_manifest=json.loads((build/'build-manifest.json').read_text()),identity=source_identity(source),
            source_launcher={'helper_hops':hops,'already_helper_routed':hops>0,'plain_hops':wrapper.count(PLAIN_EXEC)},
            helper_text=rendered,signed_artifacts=artifact_hashes(temporary,
                ARTIFACT_PATHS+(FSR_ARTIFACT_PATHS if a.fsr_translator else ())),composition=a.composition,
            fsr_translator=a.fsr_translator,
            fsr_build_manifest=(json.loads((fsr_build/'build-manifest.json').read_text()) if a.fsr_translator else None),
            native_fg_fallback=fg_provenance,d3dmetal_input_kind=d3dmetal_input_kind)
        (temporary/STAGE_MANIFEST).write_text(json.dumps(manifest,indent=2)+'\n')
        os.rename(temporary,dest)
    except BaseException:
        if temporary.exists():shutil.rmtree(temporary)
        raise
    print(f'PRIVATE runtime staged: {dest} (profile {profile})')
    if a.fsr_translator:
        print('FSR translators: builtin upscaler and frame-generation DLLs are forced after the wrapper reset; the original loader remains native.')
        print(f'Unsupported/native-version FG contexts use the verified read-only {PRIVATE_FG_PATH} fallback. YAAGL_FSR_LOG enables the bounded optional log.')
    if a.composition:
        print('Composition trace: Metal4 draw-time binding snapshots, bounded CPU buffer prefixes, queue events and drawable links during native capture. CPU prefixes are not GPU values or identified camera matrices.')
    if profile!=PLAY_PROFILE:
        print('Model policy: all GPUs use the system-default temporal model; private BBR/V4 selection is disabled. Legacy temporal repair remains disabled.')
    if profile==PLAY_PROFILE:
        print('Play profile: diagnostics disabled and game sizing unchanged. All GPUs use the system-default temporal model.')
    print(f'Use {dest}/bin/wine in the same launch command/prefix as your normal ZZZ runtime.')
    if profile!=PLAY_PROFILE:print(f'Manual captures in {probe} still work.')
    print('Do not replace the installed Yaagl runtime or use its old package hash manifest to validate this diagnostic copy.')
    print('Rollback: launch the untouched original runtime; delete the private copy when finished.')
    return 0
if __name__=='__main__':
    try:sys.exit(main())
    except (OSError,ValueError,RuntimeError,subprocess.CalledProcessError) as e:sys.exit(str(e))
