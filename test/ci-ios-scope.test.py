"""The fast CI policy must not skip iOS changes or hide missing Git evidence."""
import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    'ci_ios_scope', Path(__file__).resolve().parents[1] / 'scripts/ci-ios-scope.py')
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)


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
