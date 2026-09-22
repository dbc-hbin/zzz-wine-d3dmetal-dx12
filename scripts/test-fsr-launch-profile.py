#!/usr/bin/env python3
"""Exercise the relocatable FSR helper through its real subprocess boundary."""
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
    def test_relocated_helper_preserves_arguments_and_fsr_paths(self):
        with tempfile.TemporaryDirectory(prefix='fsr runtime ') as temp:
            root = Path(temp).resolve()
            initial = root / 'original location'
            helper = initial / 'bin' / stage.HELPER_NAME
            helper.parent.mkdir(parents=True)
            helper.write_text(stage.helper_script())
            relocated = root / 'relocated runtime'
            initial.rename(relocated)
            env = dict(os.environ)
            env['WINEDLLOVERRIDES'] = 'amd_fidelityfx_upscaler_dx12=n'
            env['YAAGL_FSR_FG_NATIVE_DLL'] = 'Z:/obsolete/runtime/provider.dll'
            code = ('import json,os,sys; print(json.dumps(['
                    'os.environ.get("WINEDLLOVERRIDES"),'
                    'os.environ.get("YAAGL_FSR_FG_NATIVE_DLL"),sys.argv[1:]]))')
            completed = subprocess.run(
                ['/bin/sh', str(relocated / 'bin' / stage.HELPER_NAME),
                 sys.executable, '-c', code, 'name with spaces', '$literal'],
                cwd=root, env=env, capture_output=True, text=True, check=True, timeout=10)
            overrides, fallback, arguments = json.loads(completed.stdout)
            self.assertEqual(overrides,
                'amd_fidelityfx_upscaler_dx12,amd_fidelityfx_framegeneration_dx12=b')
            self.assertEqual(fallback,
                f'Z:{relocated}/lib/wine/x86_64-windows/amd_fidelityfx_framegeneration_dx12_native.dll')
            self.assertEqual(arguments, ['name with spaces', '$literal'])


if __name__ == '__main__':
    unittest.main()
