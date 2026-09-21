#!/usr/bin/env python3
"""Verify the FSR runtime helper, native fallback, and manifest policy."""
import importlib.util
import json
import os
import shutil
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('stage_runtime', ROOT / 'scripts/stage-runtime.py')
stage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)


class FsrLaunchPolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        (ROOT / 'build').mkdir(exist_ok=True)

    def test_helper_overrides_wrapper_reset(self):
        with tempfile.TemporaryDirectory(dir=ROOT / 'build') as temp:
            root = Path(temp)
            helper = root / 'bin' / stage.HELPER_NAME
            helper.parent.mkdir(parents=True)
            helper.write_text(stage.helper_script(
                root / 'unused', stage.PLAY_PROFILE, fsr_translator=True))
            env = dict(os.environ)
            env['WINEDLLOVERRIDES'] = 'discarded=n'
            code = ('import json,os; print(json.dumps(['
                    'os.environ.get("WINEDLLOVERRIDES"),'
                    'os.environ.get("MTL_HUD_ENABLED"),'
                    'os.environ.get("YAAGL_FSR_FG_NATIVE_DLL")]))')
            completed = subprocess.run(
                ['/bin/sh', str(helper), 'python3', '-c', code], env=env,
                capture_output=True, text=True, check=True, timeout=10)
            overrides, hud, fallback = json.loads(completed.stdout)
            self.assertEqual(overrides, stage.FSR_OVERRIDE)
            self.assertEqual(hud, '1')
            self.assertEqual(
                fallback,
                f'Z:{root}/{stage.PRIVATE_FG_PATH}')

    @unittest.skipUnless(stage.ORIGINAL_FG_SOURCE.is_file(),
                         'requires the pinned original FG DLL')
    def test_manifest_rejects_helper_policy_drift(self):
        with tempfile.TemporaryDirectory(dir=ROOT / 'build') as temp:
            root = Path(temp)
            helper = root / 'bin' / stage.HELPER_NAME
            helper.parent.mkdir(parents=True)
            probe = root / 'unused'
            text = stage.helper_script(
                probe, stage.PLAY_PROFILE, fsr_translator=True)
            helper.write_text(text)
            fallback = root / stage.PRIVATE_FG_PATH
            fallback.parent.mkdir(parents=True)
            shutil.copy2(stage.ORIGINAL_FG_SOURCE, fallback)
            fallback.chmod(0o444)
            provenance = stage.original_fg_provenance(fallback)
            manifest = stage.stage_manifest(
                stage.PLAY_PROFILE, source=root, probe=probe,
                pristine_sha256='fixture', inspection={}, native_manifest={},
                identity={}, source_launcher={}, helper_text=text,
                fsr_translator=True, d3dmetal_input_kind='patched',
                native_fg_fallback=provenance)
            (root / stage.STAGE_MANIFEST).write_text(json.dumps(manifest))
            self.assertFalse(any(
                level == 'FAIL' for level, _ in stage.stage_manifest_report(root)))
            self.assertEqual(
                manifest['d3dmetal_input'],
                {'kind': 'patched', 'sha256': 'fixture'})
            helper.write_text(text.replace(
                stage.FSR_OVERRIDE, 'amd_fidelityfx_upscaler_dx12=n'))
            self.assertTrue(any(
                level == 'FAIL' for level, _ in stage.stage_manifest_report(root)))


if __name__ == '__main__':
    unittest.main()
