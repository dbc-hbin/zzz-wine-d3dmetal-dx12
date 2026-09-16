#!/bin/bash
set -euo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
xcrun clang++ -std=c++20 -Wall -Wextra -Werror -pthread -fsanitize=address,undefined \
  -I"$root/d3dmetal-pso-cache" "$root/d3dmetal-pso-cache/frame-probe-core.test.cpp" -o "$work/ledger-test"
"$work/ledger-test"
if [[ $(uname -s) == Darwin ]]; then
  xcrun clang++ -arch x86_64 -std=c++20 -fno-objc-arc -fobjc-exceptions -fblocks \
    -Wall -Wextra -Werror -DYAAGL_FRAME_PROBE_TESTS=1 -mmacosx-version-min=14.0 \
    -framework Foundation -framework Metal -framework QuartzCore \
    -I"$root/d3dmetal-pso-cache" \
    "$root/d3dmetal-pso-cache/frame-probe.mm" "$root/d3dmetal-pso-cache/frame-probe.test.mm" -o "$work/native-mock"
  for reset in 0 1; do
    mkdir -m 700 "$work/probe-$reset"
    YAAGL_METALFX_PROBE_RESET_HISTORY=$reset arch -x86_64 "$work/native-mock" "$work/probe-$reset"
    python3 "$root/scripts/analyze-probe.py" "$work/probe-$reset"/probe-*.jsonl --out "$work/report-$reset.json"
    python3 - "$work/report-$reset.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]));es=r['encode_table']
assert len(es)==6,es
assert [x['eval_id'] for x in es[:2]]==[2,1],es
assert es[2]['match']=='untracked_or_repeated',es
assert es[3]['match']=='record_bytes_changed',es
assert 'jitter_x' in es[4]['differences'],es
print('PASS native sidecar assertions')
PY
  done
else
  echo "NOT RUN on this host: macOS SDK build, Objective-C runtime mock, GPU capture, ZZZ."
fi
