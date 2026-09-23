#!/usr/bin/env python3
"""Exercise staged FSR policy through the real wine.real child boundary."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('stage_runtime', ROOT / 'scripts/stage-runtime.py')
stage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)


class FsrLaunchPolicyTests(unittest.TestCase):
    def test_relocated_wrapper_all_routes_and_hud(self):
        with tempfile.TemporaryDirectory(prefix='fsr runtime ') as temp:
            root = Path(temp).resolve()
            initial = root / 'original location'
            bin_dir = initial / 'bin'
            bin_dir.mkdir(parents=True)
            (bin_dir / 'wine').write_text((ROOT / 'scripts/wine-launch-wrapper.sh').read_text())
            real = bin_dir / 'wine.real'
            real.write_text('#!/bin/sh\nexec "$@"\n')
            real.chmod(0o755)
            relocated = root / 'relocated runtime'
            initial.rename(relocated)
            (relocated / stage.STAGE_MANIFEST).write_text('{}')
            support = root / 'support'
            support.mkdir()
            (support / 'config.bat').write_text('ZenlessZoneZero.exe\n')
            prefix = support / 'prefix'
            code = ('import json,os,sys;print(json.dumps({'
                    '"overrides":os.environ.get("WINEDLLOVERRIDES"),'
                    '"fallback":os.environ.get("YAAGL_FSR_FG_NATIVE_DLL"),'
                    '"hud":os.environ.get("MTL_HUD_ENABLED"),'
                    '"capture":os.environ.get("MTL_CAPTURE_ENABLED"),'
                    '"args":sys.argv[1:]}))')
            routes = (('direct', ['ZenlessZoneZero.exe']),
                      ('batch', ['config.bat']), ('other', ['winecfg']))
            for selection, expected in ((None, stage.FSR_OVERRIDE),
                                        ('native', 'amd_fidelityfx_upscaler_dx12=n;amd_fidelityfx_framegeneration_dx12=b')):
                for hud in (None, '', '0', '1'):
                    for route, suffix in routes:
                        with self.subTest(selection=selection, hud=hud, route=route):
                            env = dict(os.environ, WINEPREFIX=str(prefix),
                                       WINEDLLOVERRIDES='obsolete', YAAGL_FSR_FG_NATIVE_DLL='obsolete')
                            env.pop('YAAGL_FSR_UPSCALER', None)
                            env.pop('MTL_HUD_ENABLED', None)
                            if selection is not None:
                                env['YAAGL_FSR_UPSCALER'] = selection
                            if hud is not None:
                                env['MTL_HUD_ENABLED'] = hud
                            result = subprocess.run(['/bin/sh', str(relocated / 'bin/wine'),
                                                     sys.executable, '-c', code, *suffix, '$literal'],
                                                    cwd=root, env=env, capture_output=True, text=True,
                                                    check=True, timeout=10)
                            child = json.loads(result.stdout)
                            self.assertEqual(child['overrides'], expected)
                            self.assertEqual(child['fallback'],
                                f'Z:{relocated}/{stage.PRIVATE_FG_PATH}')
                            self.assertEqual(child['hud'], hud)
                            self.assertEqual(child['capture'], '0')
                            self.assertEqual(child['args'], suffix + ['$literal'])

    def test_unstaged_wrapper_does_not_enable_fsr_and_invalid_staged_policy_fails_closed(self):
        with tempfile.TemporaryDirectory(prefix='fsr boundary ') as temp:
            root = Path(temp)
            bin_dir = root / 'bin'
            bin_dir.mkdir()
            (bin_dir / 'wine').write_text((ROOT / 'scripts/wine-launch-wrapper.sh').read_text())
            real = bin_dir / 'wine.real'
            real.write_text('#!/bin/sh\nexec "$@"\n')
            real.chmod(0o755)
            marker = root / 'launched'
            code = 'from pathlib import Path;import sys;Path(sys.argv[1]).write_text("ran")'
            env = dict(os.environ, YAAGL_FSR_UPSCALER='invalid', MTL_HUD_ENABLED='0')
            args = ['/bin/sh', str(bin_dir / 'wine'), sys.executable, '-c', code, str(marker)]
            subprocess.run(args, env=env, capture_output=True, text=True, check=True, timeout=10)
            self.assertEqual(marker.read_text(), 'ran')
            marker.unlink()
            (root / stage.STAGE_MANIFEST).write_text('{}')
            result = subprocess.run(args, env=env, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 64)
            self.assertFalse(marker.exists())


if __name__ == '__main__':
    unittest.main()
