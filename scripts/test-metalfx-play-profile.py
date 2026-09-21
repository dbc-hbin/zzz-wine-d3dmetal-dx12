#!/usr/bin/env python3
"""CPU tests of the no-capture play runtime's real launch helper and manifest."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('stage_runtime', Path(__file__).with_name('stage-runtime.py'))
stage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)

class PlayProfileTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        (ROOT / 'build').mkdir(exist_ok=True)

    def test_manifest_and_helper_agree(self):
        with tempfile.TemporaryDirectory(dir=ROOT / 'build') as temp:
            runtime = Path(temp)
            probe = runtime / 'unused'
            text = stage.helper_script(probe, stage.PLAY_PROFILE)
            self.assertEqual(stage.helper_problems(text, probe, stage.PLAY_PROFILE), [])
            self.assertEqual(set(stage.profile_environment(stage.PLAY_PROFILE).values()), {'0'})
            self.assertNotIn('game_launch', text)
            self.assertTrue(stage.helper_problems(text.replace('export YAAGL_METALFX_FRAME_PROBE=0',
                'export YAAGL_METALFX_FRAME_PROBE=1'), probe, stage.PLAY_PROFILE))
            manifest = stage.stage_manifest(stage.PLAY_PROFILE, source=runtime, probe=probe,
                pristine_sha256='test', inspection={}, native_manifest={}, identity={},
                source_launcher={}, helper_text=text)
            self.assertEqual(manifest['render_environment_defaults'], stage.PLAY_RENDER_DEFAULTS)
            self.assertEqual(manifest['render_policy_version'],4)
            self.assertFalse(manifest['render_size_override'])
            self.assertEqual(manifest['model_policy'],
                stage.PLAY_MODEL_POLICY)
            self.assertFalse(manifest['rendering_changes_by_default'])
            self.assertEqual(manifest['probe_environment'], stage.PLAY_ENVIRONMENT)
            self.assertTrue(manifest['old_temporal_repair_disabled'])

    def test_real_helper_defaults_overrides_and_argument_preservation(self):
        with tempfile.TemporaryDirectory(dir=ROOT / 'build') as temp:
            root = Path(temp)
            helper = root / 'helper'
            helper.write_text(stage.helper_script(root / 'unused', stage.PLAY_PROFILE))
            for override in (None, 'application', 'quality', 'dlaa'):
                env = {k:v for k,v in os.environ.items() if not k.startswith('YAAGL_METALFX_')}
                env.update(YAAGL_METALFX_MODEL='bbr', YAAGL_METALFX_TEMPORAL='repair',
                    YAAGL_METALFX_TEMPORAL_TESTS='1',
                    MTL_CAPTURE_ENABLED='1', YAAGL_METALFX_FRAME_PROBE='1')
                if override: env['YAAGL_METALFX_RENDER_PRESET'] = override
                code = ('import os,sys; assert sys.argv[1:]==["name with spaces", "$literal"]; '
                    'assert "YAAGL_METALFX_RENDER_PRESET" not in os.environ; '
                    'assert os.environ["YAAGL_METALFX_ORDERING"]=="0"; '
                    'assert "YAAGL_METALFX_MODEL" not in os.environ; '
                    'assert "YAAGL_METALFX_TEMPORAL" not in os.environ; '
                    'assert "YAAGL_METALFX_TEMPORAL_TESTS" not in os.environ; '
                    'assert all(os.environ[n]=="0" for n in '+repr(list(stage.ENVIRONMENT_ORDER))+')')
                subprocess.run(['/bin/sh', str(helper), 'python3', '-c', code, 'name with spaces', '$literal'],
                    env=env, check=True, capture_output=True, text=True)
            self.assertFalse((root / 'unused').exists())

    def test_old_play_source_is_validated_then_upgraded(self):
        with tempfile.TemporaryDirectory(dir=ROOT / 'build') as temp:
            runtime = Path(temp)
            probe = runtime / 'unused'
            current = stage.helper_script(probe, stage.PLAY_PROFILE)
            old_defaults = {'YAAGL_METALFX_RENDER_PRESET':'quality',
                'YAAGL_METALFX_ORDERING':'1','YAAGL_METALFX_MODEL':'default'}
            historical = current.replace('unset '+' '.join(stage.PROBE_UNSET)+'\n',
                'unset '+' '.join(stage.HISTORICAL_PROBE_UNSET)+'\n')
            historical = historical.replace('unset '+stage.RETIRED_RENDER_ENV+'\n', '')
            for name, value in stage.PLAY_RENDER_DEFAULTS.items():
                historical = historical.replace(f'export {name}=${{{name}:-{value}}}\n', '')
            historical = historical.replace('exec "$@"',
                '\n'.join(f'export {name}=${{{name}:-{value}}}' for name, value in old_defaults.items())
                +'\nexec "$@"')
            manifest = stage.stage_manifest(stage.PLAY_PROFILE, source=runtime, probe=probe,
                pristine_sha256='test', inspection={}, native_manifest={}, identity={},
                source_launcher={}, helper_text=historical)
            manifest.pop('render_policy_version')
            manifest.pop('render_size_override')
            manifest['probe_unset'] = list(stage.HISTORICAL_PROBE_UNSET)
            manifest['render_environment_defaults'] = old_defaults
            helper = runtime/'bin'/stage.HELPER_NAME
            helper.parent.mkdir()
            helper.write_text(historical)
            (runtime/stage.STAGE_MANIFEST).write_text(json.dumps(manifest))
            verdict = stage.stage_manifest_report(runtime)
            self.assertFalse([m for level,m in verdict if level=='FAIL'], verdict)
            self.assertTrue(any('historical play policy' in m for _,m in verdict))
            self.assertNotIn('export '+stage.RETIRED_RENDER_ENV+'=', current)
            self.assertIn('unset '+stage.RETIRED_RENDER_ENV, current)
            # A mismatched historical helper is not silently accepted.
            helper.write_text(historical.replace(':-quality}', ':-dlaa}'))
            self.assertTrue(any(level=='FAIL' for level,_ in stage.stage_manifest_report(runtime)))

    def test_signed_inventory_detects_stale_sidecar_and_missing_bridge(self):
        with tempfile.TemporaryDirectory(dir=ROOT / 'build') as temp:
            root=Path(temp)
            for relative in stage.ARTIFACT_PATHS:
                path=root/relative
                path.parent.mkdir(parents=True,exist_ok=True)
                path.write_bytes(relative.encode())
            recorded=stage.artifact_hashes(root)
            self.assertEqual(stage.artifact_problems(root,recorded),[])
            sidecar=str(stage.REL/'Resources/libYaaglNativePsoCache.dylib')
            (root/sidecar).write_bytes(b'old signed module')
            self.assertEqual(stage.artifact_problems(root,recorded),
                ['signed runtime artifact changed: '+sidecar])
            (root/sidecar).write_bytes(sidecar.encode())
            (root/'lib/wine/x86_64-unix/nvngx.so').unlink()
            self.assertTrue(stage.artifact_problems(root,recorded))
            self.assertTrue(stage.artifact_problems(root,{}))

    def test_signed_inventory_is_enforced_when_restaging(self):
        with tempfile.TemporaryDirectory(dir=ROOT / 'build') as temp:
            root=Path(temp)
            probe=root/'unused'
            for relative in stage.ARTIFACT_PATHS:
                path=root/relative
                path.parent.mkdir(parents=True,exist_ok=True)
                path.write_bytes(relative.encode())
            helper=stage.helper_script(probe,stage.PLAY_PROFILE)
            (root/'bin'/stage.HELPER_NAME).write_text(helper)
            manifest=stage.stage_manifest(stage.PLAY_PROFILE,source=root,probe=probe,
                pristine_sha256='test',inspection={},native_manifest={},identity={},
                source_launcher={},helper_text=helper,signed_artifacts=stage.artifact_hashes(root))
            (root/stage.STAGE_MANIFEST).write_text(json.dumps(manifest))
            self.assertFalse(any(level=='FAIL' for level,_ in stage.verify_runtime(root)))
            (root/'bin/wine').write_text('old wrapper')
            self.assertTrue(any(level=='FAIL' for level,_ in stage.stage_manifest_report(root)))
            self.assertTrue(any(level=='FAIL' for level,_ in stage.verify_runtime(root)))

if __name__ == '__main__':
    unittest.main()
