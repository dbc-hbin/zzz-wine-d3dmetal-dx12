#!/usr/bin/env python3
"""Self-contained checks for the frame-probe host tools in scripts/."""
import importlib.util, json, os, pathlib, shutil, subprocess, sys, tempfile, unittest
sys.dont_write_bytecode=True
P=pathlib.Path(__file__).resolve().parents[1]
s=importlib.util.spec_from_file_location('analyzer',P/'scripts/analyze-probe.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m)

class AnalyzerTests(unittest.TestCase):
    def row(self,**kw):return dict(event='encode_before',pid=1,encode_id=9,eval_id=4,record_id=5,cb_oid=2,cb_epoch=0,
        match='record_bytes_match',actual={'width':100,'height':50,'jitter_x':.25,'color':{'pointer':'0x1234'},'output':{'oid':7,'pointer':'0xabcd'}},
        recorded={'width':100,'height':50,'jitter_x':.25,'color':'0x1234','output':'0xabcd'},**kw)
    def test_matching(self):self.assertEqual(m.analyze([self.row()])['state_differences'],[])
    def test_changed(self):
        r=self.row();r['actual']['jitter_x']=-.25;r['actual']['color']['pointer']='0x4567'
        self.assertEqual(m.analyze([r])['state_differences'][0]['differences'],['jitter_x','color_binding'])
    def test_zero_missing_not_confused(self):self.assertEqual(m.difference({'jitter_x':.2},{'jitter_x':None}),[])
    def test_pointer_does_not_prove_age(self):
        r=m.analyze([self.row()]);self.assertTrue(any('frame-age' in x for x in r['limits']))
        self.assertTrue(any('JSON alone' in x for x in r['warnings']))
    def test_no_encode(self):self.assertTrue(m.analyze([])['warnings'])
    def test_multiple_processes(self):
        with self.assertRaises(ValueError):m.analyze([{'pid':1},{'pid':2}])
    def test_untracked(self):self.assertEqual(m.analyze([{'pid':1,'event':'replay','match':'untracked_or_repeated'}])['uncorrelated_or_changed_replays'],1)
    def test_resource_navigation_is_not_dependency_claim(self):
        result=m.analyze([self.row(),{'pid':1,'event':'render_pass','pass_id':40,'cb_oid':2,'inside_metalfx':False,'targets':[{'texture':{'oid':7}}]}])
        self.assertEqual(result['passes_targeting_an_observed_metalfx_output'][0]['pass_id'],40)
    def test_dropped(self):self.assertTrue(any('dropped' in w for w in m.analyze([self.row(dropped_total=5)])['warnings']))
    def test_null_pointer(self):self.assertEqual(m.difference({'exposure':'(nil)'},{'exposure':{'pointer':'nil'}}),[])

class HostToolTests(unittest.TestCase):
    """Ports of the kit integration cases that exercise repo-resident tools."""
    def setUp(self):
        self.tmp=tempfile.mkdtemp();self.addCleanup(shutil.rmtree,self.tmp,ignore_errors=True)
        self.root=pathlib.Path(self.tmp)
    def test_invalid_apple_binary_is_rejected_without_mutation(self):
        wine=self.root/'wine';(wine/'bin').mkdir(parents=True)
        binary=wine/'lib/external/D3DMetal.framework/Versions/A/D3DMetal';binary.parent.mkdir(parents=True);binary.write_bytes(b'fake')
        (wine/'bin/wine').write_text('#!/bin/sh\nexec "$real_wine" "$@"\n')
        dest=self.root/'private';probe=self.root/'logs'
        result=subprocess.run(['python3',str(P/'scripts/stage-runtime.py'),'--wine-source',str(wine),'--wine-dest',str(dest),
            '--pristine-d3dmetal',str(binary),'--probe-dir',str(probe),'--check'],capture_output=True,text=True)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('SHA mismatch',result.stderr)
        self.assertFalse(dest.exists());self.assertFalse(probe.exists())
        self.assertEqual(binary.read_bytes(),b'fake')
        out=self.root/'patched'
        result=subprocess.run(['node',str(P/'scripts/d3dmetal-pso-cache-patch.mjs'),'patch',str(binary),str(out)],capture_output=True,text=True)
        self.assertNotEqual(result.returncode,0);self.assertFalse(out.exists())
    def test_capture_arm_cli_publishes_complete_json_and_refuses_duplicate(self):
        logs=self.root/'control';logs.mkdir(mode=0o700)
        (logs/f'ready-{os.getpid()}.json').write_text(json.dumps({'pid':os.getpid(),'log':str(logs/'test.jsonl')}))
        ctl=['python3',str(P/'scripts/probe-control.py'),str(logs),'capture','--presentations','8']
        subprocess.run(ctl,check=True,capture_output=True)
        arm=logs/f'capture-{os.getpid()}.arm'
        self.assertEqual(json.loads(arm.read_text())['presentations'],8)
        self.assertNotEqual(subprocess.run(ctl,capture_output=True).returncode,0)

if __name__=='__main__':unittest.main()
