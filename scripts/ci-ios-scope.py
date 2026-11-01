#!/usr/bin/env python3
"""Select iOS coverage (full, smoke or skip) and whether backend tests run, without path-filtered checks."""
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
    # Smoke is one iPhone job, so an edit to a device job's test list
    # (.github/ios-tests/) also runs full: otherwise nothing would run it.
    verification_paths = {
        '.github/workflows/ci.yml', 'scripts/verify-ios.sh',
        'scripts/ci-ios-scope.py', 'test/verify-ios.test.py',
        'test/ci-ios-scope.test.py',
    }
    if any(path in verification_paths or path.startswith('.github/ios-tests/')
           for path in paths):
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


def select_backend(event, paths=()):
    """Backend tests run unless every changed path is documentation."""
    if event in ('schedule', 'workflow_dispatch'):
        return 'run'
    if event not in ('pull_request', 'push'):
        raise ValueError('Unsupported CI event: ' + event)
    # The plan graph check still validates docs/plans on every run. Nothing
    # the backend jobs build or test reads Markdown or docs/.
    def documentation(path):
        return path.startswith('docs/') or path.endswith('.md')
    return 'skip' if paths and all(documentation(path) for path in paths) else 'run'


def suite_for_checkout(event, before=None, select=select_suite):
    if event in ('schedule', 'workflow_dispatch'):
        return select(event)
    if event == 'pull_request':
        # checkout uses GitHub's tested merge commit; its first parent is base.
        base = 'HEAD^1'
    elif event == 'push':
        if before is None or re.fullmatch(r'[0-9a-f]{40}', before) is None:
            raise ValueError('Push CI requires the before commit SHA')
        if before == '0' * 40:
            return select(event, ['<new branch>'])
        base = before
    else:
        raise ValueError('Unsupported CI event: ' + event)
    # A missing base or failed diff raises: never interpret it as no changes.
    changed = subprocess.check_output(
        ['git', 'diff', '--no-renames', '--name-only', '-z', base, 'HEAD'],
    )
    paths = changed.decode('utf-8', errors='surrogateescape').split('\0')
    return select(event, [path for path in paths if path])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--event', required=True)
    parser.add_argument('--before')
    parser.add_argument('--target', choices=['ios', 'backend'], default='ios')
    args = parser.parse_args()
    select = select_backend if args.target == 'backend' else select_suite
    print(suite_for_checkout(args.event, args.before, select))
