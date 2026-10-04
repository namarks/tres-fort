"""One source selection for disposable iOS builds and capture verification."""
import hashlib
import os
from pathlib import Path
import shutil

IGNORE = shutil.ignore_patterns(
    '*.xcodeproj', 'DerivedData', 'build', '.bundle', '.dependencies', 'vendor', 'fastlane',
    '*.xcuserstate', '.DS_Store', '.api_key.json')


def source_manifest(root):
    root = Path(root)
    result = {}

    def fail(error):
        raise error

    for directory, dirs, files in os.walk(root, onerror=fail):
        ignored = IGNORE(directory, dirs + files)
        dirs[:] = sorted(name for name in dirs if name not in ignored)
        for name in set(dirs + files) - ignored:
            if (Path(directory) / name).is_symlink():
                raise ValueError('iOS source snapshot cannot contain symbolic links')
        for name in sorted(set(files) - ignored):
            path = Path(directory) / name
            result[str(path.relative_to(root))] = hashlib.sha256(path.read_bytes()).hexdigest()
    return result


def copy_sources(source, destination):
    shutil.copytree(source, destination, ignore=IGNORE, symlinks=True)
    return source_manifest(destination)


def require_unchanged_sources(root, captured):
    if source_manifest(root) != captured:
        raise ValueError('iOS source set or contents changed during capture')
