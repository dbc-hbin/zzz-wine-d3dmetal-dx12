#!/usr/bin/env python3
"""Check CPU provenance and capture coverage; NEVER infer GPU pixel age from pointers."""
from __future__ import annotations
import argparse, collections, csv, json, math, sys
from pathlib import Path

def difference(recorded:dict, actual:dict) -> list[str]:
    problems=[]
    for key in ('width','height','jitter_x','jitter_y','mv_x','mv_y','pre_exposure'):
        x,y=recorded.get(key),actual.get(key)
        if x is None or y is None: continue
        if not math.isclose(x,y,rel_tol=1e-6,abs_tol=1e-6): problems.append(key)
    for key in ('color','depth','motion','output','exposure','reactive'):
        x=recorded.get(key);y=actual.get(key,{}).get('pointer')
        def ptr(v):
            if v in (None,'nil','(nil)','0x0'): return 0
            try:return int(v,16)
            except (ValueError,TypeError):return v
        if x is not None and y is not None and ptr(x)!=ptr(y): problems.append(key+'_binding')
    return problems

def analyze(rows:list[dict]) -> dict:
    counts=collections.Counter(r.get('event','unknown') for r in rows)
    pid_set={r.get('pid') for r in rows}
    if len(pid_set)>1: raise ValueError('Do not merge processes: Evaluate/record IDs are per process.')
    warnings=[];examples=[];encodes=[]
    replay_bad=0
    for row in rows:
        event=row.get('event')
        if event=='replay' and row.get('match')!='record_bytes_match': replay_bad+=1
        if event=='encode_before':
            diff=difference(row.get('recorded',{}),row.get('actual',{}))
            if diff:examples.append({'encode_id':row['encode_id'],'differences':diff})
            encodes.append({'encode_id':row['encode_id'],'eval_id':row.get('eval_id',0),'record_id':row.get('record_id',0),
                'cb_oid':row.get('cb_oid',0),'cb_epoch':row.get('cb_epoch',0),'capture_id':row.get('capture_id',0),
                'match':row.get('match'),'output_oid':row.get('actual',{}).get('output',{}).get('oid'),
                'differences':','.join(diff),'reset_test':row.get('history_reset_test',False)})
    if not counts['encode_before']:warnings.append('NO native encode observed: do not diagnose the UI from this run.')
    if counts['NO_NATIVE_ENCODE']:warnings.append('Replay without an observed native encode; inspect hook coverage.')
    if replay_bad:warnings.append('Some replay records are missing/repeated/changed; no guessed association was made.')
    if not counts['capture_started']:warnings.append('No successful GPU capture. JSON alone cannot locate the nameplate draw or prove texel frame age.')
    if counts['capture_started']>counts['capture_stopped']:warnings.append('Capture has not finished, or the log ended early. Do not assume the .gputrace is complete.')
    max_dropped=max((r.get('dropped_total',0) for r in rows),default=0)
    if counts['log_limit']:warnings.append('Log capacity reached: later events are missing. Restart for a new diagnostic run.')
    if any(r.get('event')=='capture_stopped' and r.get('reason')=='timeout_not_a_frame_boundary' for r in rows):
        warnings.append('Capture stopped by timeout, not a presentation callback. Final frame can be partial.')
    if max_dropped:warnings.append(f'{max_dropped} events reported dropped; coverage is incomplete.')
    if counts['probe_exception'] or counts['capture_start_failed'] or counts['capture_unavailable']:
        warnings.append('Probe/capture failures exist; inspect their events before interpreting results.')
    if examples:warnings.append('Descriptor-to-bound-state differences are candidates, not proof of a bug: deliberate conversion can be valid.')
    outputs={e['output_oid'] for e in encodes if e['output_oid']}
    direct_passes=[]
    for r in rows:
        if r.get('event')!='render_pass' or r.get('inside_metalfx'):continue
        target_ids={t.get('texture',{}).get('oid') for t in r.get('targets',[])}
        if outputs&target_ids:direct_passes.append({'pass_id':r['pass_id'],'cb_oid':r.get('cb_oid'),'target_oids':sorted(outputs&target_ids)})
    return {'counts':dict(counts),'encode_table':encodes,'state_differences':examples,'uncorrelated_or_changed_replays':replay_bad,
        'passes_targeting_an_observed_metalfx_output':direct_passes,'warnings':warnings,
        'limits':['CPU metadata only; no automatic GPU frame-age verdict.',
            'An eval_id is not a Present frame ID; a texture oid is not a content generation.',
            'Direct output-target matches are navigation hints, not a complete downstream dependency graph.',
            'Find the actual glyph/icon draw and GPU-versioned buffers in the native .gputrace.',
            'Capture changes timing; do not use it to benchmark steady-state FPS.']}

def main() -> int:
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('log',type=Path);p.add_argument('--out',type=Path)
    a=p.parse_args();rows=[];bad=[]
    for n,line in enumerate(a.log.read_text().splitlines(),1):
        if not line.strip():continue
        try:r=json.loads(line)
        except json.JSONDecodeError:bad.append(n);continue
        if r.get('source')=='zzz-frame-probe':rows.append(r)
    result=analyze(rows)
    if bad:result['warnings'].append(f'Malformed/truncated log lines: {bad[:20]}')
    output=a.out or a.log.with_suffix('.report.json');output.write_text(json.dumps(result,indent=2,ensure_ascii=False)+'\n')
    csvpath=output.with_suffix('.encodes.csv')
    with csvpath.open('w',newline='') as stream:
        fields=['encode_id','eval_id','record_id','cb_oid','cb_epoch','capture_id','match','output_oid','differences','reset_test']
        w=csv.DictWriter(stream,fieldnames=fields);w.writeheader();w.writerows(result['encode_table'])
    print(json.dumps({'counts':result['counts'],'warnings':result['warnings'],'report':str(output),'encode_csv':str(csvpath)},indent=2,ensure_ascii=False))
    return 2 if not result['counts'].get('encode_before') or bad else 0

if __name__=='__main__':
    try:sys.exit(main())
    except (OSError,ValueError,KeyError) as e:sys.exit(str(e))
