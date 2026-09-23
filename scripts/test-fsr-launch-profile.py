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
            env.pop('YAAGL_FSR_UPSCALER', None)
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

    def test_native_upscaler_selection_survives_full_wrapper(self):
        with tempfile.TemporaryDirectory(prefix='fsr native ') as temp:
            root = Path(temp)
            bin_dir = root / 'bin'
            bin_dir.mkdir()
            helper = bin_dir / stage.HELPER_NAME
            helper.write_text(stage.helper_script())
            helper.chmod(0o755)
            wrapper = bin_dir / 'wine'
            wrapper.write_text((ROOT / 'scripts/wine-launch-wrapper.sh').read_text().replace(
                stage.PLAIN_EXEC, stage.HELPER_EXEC))
            real = bin_dir / 'wine.real'
            real.write_text('#!/bin/sh\nexec "$@"\n')
            real.chmod(0o755)
            env = dict(os.environ, YAAGL_FSR_UPSCALER='native',
                       WINEDLLOVERRIDES='amd_fidelityfx_upscaler_dx12=b')
            code = 'import os; print(os.environ["WINEDLLOVERRIDES"])'
            result = subprocess.run(['/bin/sh', str(wrapper), sys.executable, '-c', code],
                                    env=env, capture_output=True, text=True, check=True, timeout=10)
            self.assertEqual(result.stdout.strip(),
                'amd_fidelityfx_upscaler_dx12=n;amd_fidelityfx_framegeneration_dx12=b')

    def test_invalid_upscaler_selection_does_not_launch_child(self):
        with tempfile.TemporaryDirectory(prefix='fsr invalid ') as temp:
            helper = Path(temp) / stage.HELPER_NAME
            helper.write_text(stage.helper_script())
            marker = Path(temp) / 'launched'
            result = subprocess.run(
                ['/bin/sh', str(helper), sys.executable, '-c',
                 'from pathlib import Path; import sys; Path(sys.argv[1]).touch()', str(marker)],
                env=dict(os.environ, YAAGL_FSR_UPSCALER='unknown'),
                capture_output=True, text=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(marker.exists())

    def test_helper_preserves_caller_metal_hud_setting(self):
        with tempfile.TemporaryDirectory(prefix='fsr hud ') as temp:
            root = Path(temp)
            helper = root / 'bin' / stage.HELPER_NAME
            helper.parent.mkdir()
            helper.write_text(stage.helper_script())
            code = 'import json,os; print(json.dumps(os.environ.get("MTL_HUD_ENABLED")))'
            for value in (None, '', '0', '1'):
                with self.subTest(caller_value=value):
                    env = dict(os.environ)
                    env.pop('YAAGL_FSR_UPSCALER', None)
                    env.pop('MTL_HUD_ENABLED', None)
                    if value is not None:
                        env['MTL_HUD_ENABLED'] = value
                    completed = subprocess.run(
                        ['/bin/sh', str(helper), sys.executable, '-c', code],
                        cwd=root, env=env, capture_output=True, text=True, check=True, timeout=10)
                    self.assertEqual(json.loads(completed.stdout), value)


if __name__ == '__main__':
    unittest.main()
