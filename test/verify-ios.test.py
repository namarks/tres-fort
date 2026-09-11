"""Verify process failures cannot produce green CI or leak disposable devices."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts' / 'verify-ios.sh'

class VerifyIOSTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='verify-ios-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'scripts').mkdir()
        (self.root / 'ios').mkdir()
        (self.root / 'scratch').mkdir()
        (self.root / 'bin').mkdir()
        (self.root / 'bin' / 'python3').symlink_to(Path(sys.executable).resolve())
        (self.root / 'ios' / 'project.yml').write_text('name: Test\n')
        shutil.copy(SCRIPT, self.root / 'scripts' / SCRIPT.name)
        shutil.copy(SCRIPT.parent / 'ios_sources.py', self.root / 'scripts' / 'ios_sources.py')
        mock = '''#!/usr/bin/env python3
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['MOCK_CALLS'], 'a') as f: f.write(json.dumps([name, args]) + '\\n')
if name == 'xcrun':
    if args[:3] == ['simctl', 'list', 'runtimes']:
        print(json.dumps({'runtimes': [{'identifier': 'runtime', 'isAvailable': True}]}))
    elif args[:3] == ['simctl', 'list', 'devicetypes']:
        print(json.dumps({'devicetypes': [{'identifier': 'device'}]}))
    elif args[:2] == ['simctl', 'create']: print('disposable-simulator')
    elif args[:2] == ['simctl', 'boot']: sys.exit(int(os.environ.get('MOCK_BOOT_EXIT', '0')))
    elif args[:2] == ['simctl', 'bootstatus']: sys.exit(int(os.environ.get('MOCK_BOOTSTATUS_EXIT', '0')))
    elif args[:2] == ['simctl', 'ui']: sys.exit(int(os.environ.get('MOCK_UI_EXIT', '0')))
    elif args[:2] == ['simctl', 'delete']: sys.exit(int(os.environ.get('MOCK_DELETE_EXIT', '0')))
elif name == 'xcodebuild' and args[0] in ['build-for-testing', 'test-without-building']:
    result = pathlib.Path(args[args.index('-resultBundlePath') + 1])
    result.mkdir()
    (result / 'result.txt').write_text('synthetic evidence')
    print('build/test diagnostic')
    failure = 'MOCK_BUILD_EXIT' if args[0] == 'build-for-testing' else 'MOCK_TEST_EXIT'
    sys.exit(int(os.environ.get(failure, '0')))
else: print('synthetic-tool-version')
'''
        for name in ['xcrun', 'xcodegen', 'xcodebuild', 'git']:
            path = self.root / 'bin' / name
            path.write_text(mock)
            path.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.root/'bin')+os.pathsep+os.environ['PATH'],
                        TMPDIR=str(self.root/'scratch'), MOCK_CALLS=str(self.root/'calls.jsonl'))
        self.env.pop('IOS_KEEP_RESULTS', None)
        self.env.pop('IOS_EVIDENCE_DIR', None)

    def run_script(self, args=None):
        args = args if args is not None else ['--runtime','runtime','--device','device']
        result = subprocess.run(['bash',str(self.root/'scripts'/SCRIPT.name),*args],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(list((self.root/'scratch').glob('tres-fort-ios.*')), [], result.stderr)
        return result

    def calls(self):
        path=self.root/'calls.jsonl'
        return [json.loads(row) for row in path.read_text().splitlines()] if path.exists() else []

    def test_requires_explicit_selection_before_creating_device(self):
        self.assertEqual(self.run_script([]).returncode, 2)
        self.assertEqual(self.calls(), [])

    def test_invalid_runtime_cleans_scratch_and_never_creates_simulator(self):
        result=self.run_script(['--runtime','missing','--device','device'])
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(any(args[:2]==['simctl','create'] for _,args in self.calls()))

    def test_success_removes_owned_device_and_outputs(self):
        self.assertEqual(self.run_script().returncode,0)
        self.assertIn(['xcrun',['simctl','delete','disposable-simulator']],self.calls())
        self.assertFalse((self.root/'.artifacts').exists())

    def test_test_failure_remains_failure_with_retained_evidence_and_cleanup(self):
        self.env['MOCK_TEST_EXIT']='65'
        result=self.run_script(['--runtime','runtime','--device','device','--only-testing','TresFortTests'])
        self.assertNotEqual(result.returncode,0)
        self.assertIn(['xcrun',['simctl','delete','disposable-simulator']],self.calls())
        self.assertEqual(len(list((self.root/'.artifacts').rglob('result.txt'))),2)
        self.assertIn('-only-testing:TresFortTests',next(args for name,args in self.calls() if name=='xcodebuild' and args[0]=='test-without-building'))

    def test_build_failure_retains_diagnostics_and_never_runs_tests(self):
        self.env['MOCK_BUILD_EXIT']='65'
        self.assertNotEqual(self.run_script().returncode,0)
        self.assertIn(['xcrun',['simctl','delete','disposable-simulator']],self.calls())
        self.assertFalse(any(name=='xcodebuild' and args[0]=='test-without-building' for name,args in self.calls()))
        self.assertEqual(len(list((self.root/'.artifacts').rglob('build.log'))),1)

    def test_boot_failures_remain_failures_and_clean_owned_device(self):
        for failure in ['MOCK_BOOT_EXIT', 'MOCK_BOOTSTATUS_EXIT']:
            with self.subTest(failure=failure):
                self.env[failure]='1'
                self.assertNotEqual(self.run_script().returncode,0)
                self.assertIn(['xcrun',['simctl','delete','disposable-simulator']],self.calls())
                self.assertFalse(any(name=='xcodebuild' and args[0]=='test-without-building' for name,args in self.calls()))
                self.env.pop(failure)

    def test_boot_overlaps_build_and_tests_reuse_same_build_and_device(self):
        self.assertEqual(self.run_script().returncode,0)
        calls=self.calls()
        build=next(args for name,args in calls if name=='xcodebuild' and args[0]=='build-for-testing')
        test=next(args for name,args in calls if name=='xcodebuild' and args[0]=='test-without-building')
        self.assertLess(calls.index(['xcrun',['simctl','boot','disposable-simulator']]),calls.index(['xcodebuild',build]))
        self.assertLess(calls.index(['xcodebuild',build]),calls.index(['xcrun',['simctl','bootstatus','disposable-simulator','-b']]))
        self.assertLess(calls.index(['xcrun',['simctl','bootstatus','disposable-simulator','-b']]),calls.index(['xcodebuild',test]))
        for option in ['-project','-scheme','-destination','-derivedDataPath']:
            self.assertEqual(build[build.index(option)+1],test[test.index(option)+1])
        self.assertEqual(test[test.index('-parallel-testing-enabled')+1],'NO')

    def test_ci_shards_are_complementary_and_reject_extra_filters(self):
        for shard, prefix in [('1','-skip-testing:'),('2','-only-testing:')]:
            with self.subTest(shard=shard):
                result=self.run_script(['--runtime','runtime','--device','device','--ci-shard',shard])
                self.assertEqual(result.returncode,0,result.stderr)
                args=[args for name,args in self.calls() if name=='xcodebuild' and args[0]=='test-without-building'][-1]
                selection=[arg for arg in args if arg.startswith(('-only-testing:', '-skip-testing:'))]
                self.assertEqual(selection,[prefix+'TresFortUITests/HistoryJourneyTests',prefix+'TresFortUITests/ExerciseGroupJourneyTests'])
        for extra in [['--ci-shard','3'],['--ci-shard','1','--only-testing','TresFortTests']]:
            calls_before=self.calls()
            self.assertEqual(self.run_script(['--runtime','runtime','--device','device',*extra]).returncode,2)
            self.assertEqual(self.calls(),calls_before)

    def test_smoke_shards_keep_all_unit_tests_and_existing_critical_ui_flows(self):
        selections=[]
        for shard in ['1','2']:
            result=self.run_script(['--runtime','runtime','--device','device',
                                    '--ui-suite','smoke','--ci-shard',shard])
            self.assertEqual(result.returncode,0,result.stderr)
            args=[args for name,args in self.calls() if name=='xcodebuild' and args[0]=='test-without-building'][-1]
            selections.extend(arg.removeprefix('-only-testing:') for arg in args if arg.startswith('-only-testing:'))
        self.assertEqual(len(selections),14)
        self.assertIn("TresFortUITests/TodayNavigationJourneyTests", selections)
        self.assertIn("TresFortUITests/WorkoutLibraryJourneyTests", selections)
        self.assertIn("TresFortUITests/PlanChangeJourneyTests", selections)
        self.assertIn("TresFortUITests/CoachingContextJourneyTests", selections)
        self.assertIn("TresFortUITests/MemberActivationJourneyTests", selections)
        self.assertIn("TresFortUITests/IntervalsConnectionJourneyTests", selections)
        self.assertIn("TresFortUITests/GroupSafetyJourneyTests", selections)
        self.assertEqual(len(set(selections)),14)
        self.assertIn('TresFortTests',selections)
        root=SCRIPT.parents[1]/'ios'
        for selection in selections:
            if selection=='TresFortTests': continue
            target,suite,*methods=selection.split('/')
            source=(root/target/(suite+'.swift')).read_text()
            if methods:
                self.assertRegex(source,rf'func\s+{re.escape(methods[0])}\s*\(')
            else:
                self.assertRegex(source,rf'class\s+{re.escape(suite)}\s*:\s*XCTestCase')
        for extra in [['--ui-suite','invalid'],
                      ['--ui-suite','smoke','--only-testing','TresFortTests']]:
            calls_before=self.calls()
            self.assertEqual(self.run_script(['--runtime','runtime','--device','device',*extra]).returncode,2)
            self.assertEqual(self.calls(),calls_before)

    def test_system_text_setting_failure_cleans_device_without_running_tests(self):
        self.env['MOCK_UI_EXIT']='1'
        result=self.run_script(['--runtime','runtime','--device','device',
                                '--content-size','accessibility-extra-extra-extra-large'])
        self.assertNotEqual(result.returncode,0)
        self.assertIn(['xcrun',['simctl','delete','disposable-simulator']],self.calls())
        self.assertFalse(any(name=='xcodebuild' and args[0]=='test-without-building' for name,args in self.calls()))
        self.assertEqual(len(list((self.root/'.artifacts').rglob('ui-settings.log'))),1)

    def test_cleanup_failure_is_not_a_green_run(self):
        self.env['MOCK_DELETE_EXIT']='1'
        self.assertNotEqual(self.run_script().returncode,0)
        self.assertEqual(len(list((self.root/'.artifacts').rglob('cleanup.log'))),1)

if __name__ == '__main__': unittest.main()
