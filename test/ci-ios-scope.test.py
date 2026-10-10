"""The fast CI policy must not skip iOS changes or hide missing Git evidence."""
import importlib.util
from pathlib import Path
import re
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    'ci_ios_scope', Path(__file__).resolve().parents[1] / 'scripts/ci-ios-scope.py')
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)
ROOT = Path(__file__).resolve().parents[1]


def device_lists():
    """Selectors per device job, parsed as scripts/verify-ios.sh reads them."""
    lists = {}
    for path in sorted((ROOT / '.github/ios-tests').glob('*.txt')):
        lines = (line.split('#', 1)[0].strip() for line in path.read_text().splitlines())
        lists[path.stem] = [line for line in lines if line]
    return lists


class IOSScopeTests(unittest.TestCase):
    def test_periodic_and_manual_runs_always_include_full_suite(self):
        for event in ['schedule', 'workflow_dispatch']:
            with patch.object(policy.subprocess, 'check_output') as diff:
                self.assertEqual(policy.suite_for_checkout(event), 'full')
                diff.assert_not_called()

    def test_backend_and_documentation_only_changes_skip_ios(self):
        for event in ['pull_request', 'push']:
            self.assertEqual(policy.select_suite(event, [
                'src/db.ts', 'test/api.test.ts', 'docs/DESIGN.md',
                'migrations/0045_example.sql', 'README.md', 'vitest.config.ts',
            ]), 'skip')

    def test_ios_shared_fixtures_and_unknown_paths_run_smoke(self):
        for path in ['ios/TresFort/App.swift', 'ios/project.yml',
                     'ios/TresFortTests/Fixtures/CalendarProjection.json',
                     'package.json', 'new-tool.conf']:
            self.assertEqual(policy.select_suite('pull_request', ['docs/note.md', path]), 'smoke')

    def test_verification_changes_require_full_coverage_before_merge(self):
        for event in ['pull_request', 'push']:
            for path in ['.github/workflows/ci.yml', 'scripts/verify-ios.sh',
                         'scripts/ci-ios-scope.py', 'test/verify-ios.test.py',
                         'test/ci-ios-scope.test.py']:
                self.assertEqual(policy.select_suite(event, ['docs/note.md', path]), 'full')

    def test_device_test_lists_run_smoke_not_full(self):
        # Adding a class to a device job must not escalate to all six shards.
        for name in ['station', 'app-store-iphone', 'app-store-ipad']:
            self.assertEqual(policy.select_suite(
                'pull_request', [f'.github/ios-tests/{name}.txt']), 'smoke')

    def test_device_test_lists_name_real_suites(self):
        ios = ROOT / 'ios'
        for name, selectors in device_lists().items():
            self.assertTrue(selectors, name)
            self.assertEqual(len(selectors), len(set(selectors)), name)
            for selector in selectors:
                with self.subTest(list=name, selector=selector):
                    target, *rest = selector.split('/')
                    self.assertIn(target, ['TresFortTests', 'TresFortUITests'])
                    if rest:
                        source = (ios / target / (rest[0] + '.swift')).read_text()
                        self.assertRegex(source, rf'class\s+{re.escape(rest[0])}\b')
                    if len(rest) == 2:
                        self.assertRegex(source, rf'func\s+{re.escape(rest[1])}\s*\(')

    def test_public_device_shards_require_camera_gate_and_native_ui_coverage(self):
        workflow = (ROOT / '.github/workflows/ci.yml').read_text()
        steps = dict(re.findall(r'      - name: ([^\n]+)\n(.*?)(?=\n      - |\n  [a-z]|\Z)',
                                workflow, re.S))
        job_name = re.search(r'  ios-tests:\n    name: ([^\n]+)', workflow).group(1)
        lists = device_lists()
        for family, device in [('iPhone', 'iPhone-17-Pro'), ('iPad', 'iPad-Pro-13-inch-M4-8GB')]:
            step = steps[f'{family} App Store build and tests']
            self.assertIn(f'- shard: app-store-{family.lower()}', workflow)
            self.assertIn(f"matrix.shard == 'app-store-{family.lower()}' && '{family} App Store'", job_name)
            self.assertIn("APP_STORE_BUILD: '1'", step)
            self.assertIn(f'--device com.apple.CoreSimulator.SimDeviceType.{device}', step)
            self.assertIn(f'--only-testing-file .github/ios-tests/app-store-{family.lower()}.txt', step)
            self.assertIn('TresFortUITests/AppStoreScreenshotTests', lists[f'app-store-{family.lower()}'])
        for suite in ['TresFortTests/StationMediaPipeDetectorTests', 'TresFortTests/PublicStationTests']:
            self.assertIn(suite, lists['app-store-iphone'])
        # Require the entire public unit target, not a similarly prefixed class.
        for suite in ['TresFortTests', 'TresFortUITests/PublicStationJourneyTests',
                      'TresFortUITests/IpadWorkoutDisplayJourneyTests',
                      'TresFortUITests/MemberActivationJourneyTests/testFreshDeviceSignInRestoresExistingTrainingAndStation']:
            self.assertIn(suite, lists['app-store-ipad'])
        self.assertNotIn('--skip-testing', steps['iPad App Store build and tests'])
        self.assertNotIn('APP_STORE_BUILD', steps['iPad Station build and tests'])
        self.assertIn('--only-testing-file .github/ios-tests/station.txt',
                      steps['iPad Station build and tests'])
        for suite in ['StationJourneyTests', 'IpadWorkoutDisplayJourneyTests']:
            self.assertIn('TresFortUITests/' + suite, lists['station'])

    def test_pull_request_compares_tested_merge_with_base_and_preserves_paths(self):
        with patch.object(policy.subprocess, 'check_output', return_value=
                          b'docs/name with\na newline.md\0ios/deleted.swift\0docs/renamed.swift\0') as diff:
            self.assertEqual(policy.suite_for_checkout('pull_request'), 'smoke')
            diff.assert_called_once_with(
                ['git', 'diff', '--no-renames', '--name-only', '-z', 'HEAD^1', 'HEAD'])

    def test_push_compares_entire_push_including_earlier_ios_change(self):
        before = 'a' * 40
        with patch.object(policy.subprocess, 'check_output', return_value=
                          b'ios/earlier.swift\0docs/latest.md\0') as diff:
            self.assertEqual(policy.suite_for_checkout('push', before), 'smoke')
            diff.assert_called_once_with(
                ['git', 'diff', '--no-renames', '--name-only', '-z', before, 'HEAD'])

    def test_missing_git_evidence_cannot_report_skip(self):
        for event, before in [('pull_request', None), ('push', 'a' * 40)]:
            with patch.object(policy.subprocess, 'check_output', side_effect=
                              subprocess.CalledProcessError(128, 'git')):
                with self.assertRaises(subprocess.CalledProcessError):
                    policy.suite_for_checkout(event, before)
        for before in [None, '', '--bad-ref']:
            with self.assertRaises(ValueError):
                policy.suite_for_checkout('push', before)
        self.assertEqual(policy.suite_for_checkout('push', '0' * 40), 'smoke')


if __name__ == '__main__':
    unittest.main()
