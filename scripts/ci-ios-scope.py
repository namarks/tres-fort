#!/usr/bin/env python3
"""Select full, smoke, or skipped iOS verification without path-filtered checks."""
import argparse
import re
import subprocess


def select_suite(event, paths=()):
    if event in ('schedule', 'workflow_dispatch'):
        return 'full'
    if event not in ('pull_request', 'push'):
        raise ValueError('Unsupported CI event: ' + event)

    # Changes to the selection/partition machinery must prove full coverage on
    # the PR itself; a passing smoke run cannot validate the nightly job budget.
    verification_paths = {
        '.github/workflows/ci.yml', 'scripts/verify-ios.sh',
        'scripts/ci-ios-scope.py', 'test/verify-ios.test.py',
        'test/ci-ios-scope.test.py',
    }
    if any(path in verification_paths for path in paths):
        return 'full'

    def unrelated(path):
        return (
            path.startswith(('src/', 'migrations/', 'docs/'))
            or (path.startswith('test/') and path.endswith('.test.ts'))
            or path in ('README.md', 'AGENTS.md', 'CLAUDE.md', 'tsconfig.json',
                        'vitest.config.ts', 'wrangler.jsonc')
        )

    # Unknown paths run iOS. Renames are passed as deletion + addition, so
    # moving a file out of ios/ cannot accidentally skip its verification.
    return 'skip' if all(unrelated(path) for path in paths) else 'smoke'


def suite_for_checkout(event, before=None):
    if event in ('schedule', 'workflow_dispatch'):
        return select_suite(event)
    if event == 'pull_request':
        # checkout uses GitHub's tested merge commit; its first parent is base.
        base = 'HEAD^1'
    elif event == 'push':
        if before is None or re.fullmatch(r'[0-9a-f]{40}', before) is None:
            raise ValueError('Push CI requires the before commit SHA')
        if before == '0' * 40:
            return 'smoke'
        base = before
    else:
        raise ValueError('Unsupported CI event: ' + event)
    # A missing base or failed diff raises: never interpret it as no changes.
    changed = subprocess.check_output(
        ['git', 'diff', '--no-renames', '--name-only', '-z', base, 'HEAD'],
    )
    paths = changed.decode('utf-8', errors='surrogateescape').split('\0')
    return select_suite(event, [path for path in paths if path])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--event', required=True)
    parser.add_argument('--before')
    args = parser.parse_args()
    print(suite_for_checkout(args.event, args.before))
