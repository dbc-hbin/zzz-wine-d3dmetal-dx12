#!/usr/bin/env python3
"""Check scaler bindings from one serialized ngx-smoke.cpp run, not a game log."""

import argparse
import json
from pathlib import Path
import re

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('backend', choices=('legacy', 'mpl'))
parser.add_argument('jsonl', type=Path)
parser.add_argument('stdout', type=Path)
args = parser.parse_args()


def require(condition, message):
    if not condition:
        raise SystemExit('NGX_EXPOSURE_CHECK_FAIL: ' + message)


stdout = args.stdout.read_text()
require('NGX_SMOKE_PASS' in stdout.splitlines(), 'fixture did not complete')
names = re.findall(r'^NGX_SMOKE_RESULT name=(\S+) ', stdout, re.MULTILINE)
require(len(names) == len(set(names)), 'duplicate fixture case names')
exposure_cases = {
    'fallback-half', 'texture-half', 'fallback-one-and-half',
    'texture-one-and-half', 'explicit-texture-scale-unmodified',
}
require(exposure_cases | {'auto-exposure-scale-unmodified'} <= set(names), 'required fixture cases missing')
expected_source = 'mtl-encode' if args.backend == 'legacy' else 'mpl-replay'
inputs = {}
observed = {}
pids = set()
evaluation_count = 0
current = None
# The fixture waits for GPU completion before starting each next evaluation.
# Its first command is replayed twice; its final evaluation is never submitted.
# Pair by this serialization, not by pointer addresses (which may be reused).
with args.jsonl.open() as stream:
    for line in stream:
        event = json.loads(line)
        pids.add(event['pid'])
        source, phase = event['source'], event['phase']
        if source == 'ngx-evaluate' and phase == 'before':
            current = names[evaluation_count] if evaluation_count < len(names) else None
            evaluation_count += 1
            if current is not None:
                inputs[current] = event
        elif source in ('mtl-encode', 'mpl-replay') and phase == 'after':
            require(source == expected_source, 'unexpected backend: ' + source)
            require(current is not None, 'encode without a submitted fixture case')
            observed.setdefault(current, []).append(event)
require(len(pids) == 1, 'expected exactly one process log')
require(evaluation_count == len(names) + 1, 'incomplete or combined fixture log')
require(set(observed) == set(names), 'missing GPU execution for a fixture case')
for name, events in observed.items():
    for event in events:
        if name in exposure_cases:
            require(event['exposure'] is not None, name + ': exposure texture missing')
            shape = tuple(event.get('exposure_' + key) for key in ('width', 'height', 'format'))
            require(shape == (1, 1, 25), name + ': expected 1x1 MTLPixelFormatR16Float')
        else:
            require(event['exposure'] is None, name + ': unexpected exposure override')
        require(event['reactive'] is None, name + ': reactive mask was invented')
for name, scale in (('fallback-half', 0.5), ('fallback-one-and-half', 1.5)):
    require(inputs[name]['ExposureTexture'] is None and inputs[name]['DLSS.Exposure.Scale'] == scale,
            name + ': fixture input does not exercise the fallback')
caller_textures = {event['exposure'] for name in ('texture-half', 'texture-one-and-half') for event in observed[name]}
for name in ('fallback-half', 'fallback-one-and-half'):
    require(all(event['exposure'] not in caller_textures for event in observed[name]),
            name + ': fallback reused a caller-owned texture')
original = observed['texture-one-and-half'][0]['exposure']
require(inputs['texture-one-and-half']['ExposureTexture'] == inputs['explicit-texture-scale-unmodified']['ExposureTexture'],
        'explicit texture fixture identity changed')
require(all(event['exposure'] == original for event in observed['explicit-texture-scale-unmodified']),
        'caller texture was replaced despite an explicit exposure input')
print('NGX_EXPOSURE_CHECK_PASS backend=' + args.backend + ' cases=' + str(len(observed)))
