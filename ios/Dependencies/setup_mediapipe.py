#!/usr/bin/env python3
"""Install pinned public MediaPipe artifacts; no package manager or credentials."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import tarfile
import tempfile
import urllib.request
from audit_mediapipe import audit_install


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def checked_download(artifact, cache):
    path = cache / artifact['filename']
    if not path.exists():
        with tempfile.TemporaryDirectory(prefix='download-', dir=cache) as temporary:
            candidate = Path(temporary) / path.name
            with urllib.request.urlopen(artifact['url'], timeout=120) as source, candidate.open('wb') as out:
                shutil.copyfileobj(source, out)
            if sha256(candidate) != artifact['sha256']:
                raise ValueError('Downloaded SHA-256 mismatch: ' + path.name)
            os.replace(candidate, path)
    if sha256(path) != artifact['sha256']:
        raise ValueError('Cached SHA-256 mismatch; remove this cache file and rerun: ' + str(path))
    return path


def extract_archive(archive, destination):
    destination.mkdir(parents=True)
    with tarfile.open(archive, 'r:gz') as source:
        for member in source.getmembers():
            relative = Path(member.name)
            if relative.is_absolute() or '..' in relative.parts or not (member.isfile() or member.isdir()):
                raise ValueError('Unsafe archive member: ' + member.name)
            target = destination / relative
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with source.extractfile(member) as contents, target.open('wb') as out:
                    shutil.copyfileobj(contents, out)


def inventory(root):
    result = {}
    for path in sorted(root.rglob('*')):
        if path.is_symlink():
            raise ValueError('Dependency directory cannot contain symbolic links')
        if path.is_file() and path.name != 'installed.json':
            result[str(path.relative_to(root))] = sha256(path)
    return result


def install(lock_path, destination, cache):
    lock = json.loads(lock_path.read_text())
    destination.parent.mkdir(parents=True, exist_ok=True)
    cache.mkdir(parents=True, exist_ok=True)
    # Project generation and verification may run concurrently in this checkout.
    with (destination.parent / 'mediapipe-install.lock').open('w') as mutex:
        fcntl.flock(mutex, fcntl.LOCK_EX)
        receipt = destination / 'installed.json'
        if receipt.exists():
            previous = json.loads(receipt.read_text())
            if previous['lock'] == lock and previous['files'] == inventory(destination):
                print('MediaPipe and Full model: verified installed artifacts')
                return
        with tempfile.TemporaryDirectory(prefix='mediapipe-', dir=destination.parent) as temporary:
            stage = Path(temporary) / 'install'
            stage.mkdir()
            for artifact in lock['artifacts']:
                downloaded = checked_download(artifact, cache)
                if artifact['filename'].endswith('.tar.gz'):
                    extract_archive(downloaded, stage / artifact['name'])
                else:
                    shutil.copyfile(downloaded, stage / artifact['filename'])
            notices = stage / 'Notices'
            notices.mkdir()
            for name in ['LICENSE']:
                # 0.10.21 supplies identical LICENSE files, with additional
                # component notices included in that file; no separate NOTICE.
                common = stage / 'MediaPipeTasksCommon' / name
                if common.read_bytes() != (stage / 'MediaPipeTasksVision' / name).read_bytes():
                    raise ValueError('MediaPipe notices differ; review both before updating the pin')
                shutil.copyfile(common, notices / ('MediaPipe-' + name + '.txt'))
            (stage / 'installed.json').write_text(json.dumps({'lock': lock, 'files': inventory(stage)}, indent=2) + '\n')
            if destination.exists():
                shutil.rmtree(destination)
            os.replace(stage, destination)
        print('MediaPipe and Full model: installed checksum-verified artifacts')


if __name__ == '__main__':
    ios = Path(__file__).resolve().parent.parent
    dependencies = ios / '.dependencies'
    cache = Path(os.environ.get('TRESFORT_MEDIAPIPE_CACHE', str(dependencies / 'downloads')))
    install(ios / 'Dependencies' / 'mediapipe.lock.json', dependencies / 'mediapipe', cache)
    audit_install(dependencies / 'mediapipe', ios / 'Dependencies' / 'mediapipe-audit.json')
