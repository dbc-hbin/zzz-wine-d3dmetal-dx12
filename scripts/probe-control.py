#!/usr/bin/env python3
"""Arm/stop this probe in an already running game. No process injection or signals."""
from __future__ import annotations
import argparse, json, os, stat, sys, tempfile
from pathlib import Path

def alive(pid: int) -> bool:
    try: os.kill(pid, 0); return True
    except ProcessLookupError: return False
    except PermissionError: return False

def main() -> int:
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('directory',type=Path)
    p.add_argument('action',choices=['list','capture','stop'])
    p.add_argument('--pid',type=int)
    p.add_argument('--presentations',type=int,default=8)
    p.add_argument('--timeout',type=int,default=15)
    a=p.parse_args(); root=a.directory.expanduser().absolute()
    info=root.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid!=os.geteuid() or info.st_mode&0o077:
        p.error('directory must be owned by you, mode 0700, and not a symlink')
    candidates=[]
    for path in sorted(root.glob('ready-*.json')):
        if path.is_symlink(): continue
        item=json.loads(path.read_text())
        if alive(int(item['pid'])): candidates.append(item)
    if a.action=='list':
        print(json.dumps(candidates,indent=2,ensure_ascii=False));return 0
    selected=[x for x in candidates if a.pid is None or x['pid']==a.pid]
    if len(selected)!=1:
        p.error(f'expected one live process with an observed MPL Evaluate; found {len(selected)}. Use list and --pid.')
    pid=int(selected[0]['pid'])
    if not 2<=a.presentations<=32 or not 2<=a.timeout<=60:
        p.error('presentations must be 2..32; timeout must be 2..60 seconds')
    name=f'capture-{pid}.arm' if a.action=='capture' else f'stop-{pid}'
    dest=root/name
    body=json.dumps({'presentations':a.presentations,'timeout_seconds':a.timeout}).encode() if a.action=='capture' else b''
    # O_EXCL avoids overwriting an unconsumed request/symlink. Publish complete
    # bytes atomically, so a frame hook cannot read a half-written JSON file.
    fd,tmp=tempfile.mkstemp(prefix='.request-',dir=root)
    try:
        with os.fdopen(fd,'wb') as stream: stream.write(body)
        os.link(tmp,dest,follow_symlinks=False)
    finally: os.unlink(tmp)
    print(f'{a.action} requested for pid {pid}; log={selected[0]["log"]}')
    print('Keep the camera moving. A request is not proof of a successful capture; check capture_started/capture_stopped.')
    return 0

if __name__=='__main__':
    try: sys.exit(main())
    except (OSError,ValueError,KeyError) as e: sys.exit(str(e))
