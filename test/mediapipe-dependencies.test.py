"""Dependency setup rejects bad bytes and unsafe archives without network access."""
import hashlib
import io
import json
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'ios' / 'Dependencies'))
sys.path.insert(0, str(ROOT / 'scripts'))
from setup_mediapipe import checked_download, extract_archive, install, sha256
from audit_mediapipe import check_symbols
from ios_sources import copy_sources


class MediaPipeDependenciesTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='mediapipe-dependency-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.cache = self.root / 'cache'
        self.cache.mkdir()

    def archive(self, name, members):
        path = self.cache / (name + '.tar.gz')
        with tarfile.open(path, 'w:gz') as archive:
            for member, payload in members.items():
                info = tarfile.TarInfo(member)
                info.size = len(payload)
                archive.addfile(info, io.BytesIO(payload))
        return {'name': name, 'filename': path.name, 'url': 'https://invalid.invalid/unused', 'sha256': sha256(path)}

    def test_checksum_mismatch_is_rejected_before_use(self):
        artifact = self.archive('bad', {'payload': b'valid'})
        (self.cache / artifact['filename']).write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'SHA-256 mismatch'):
            checked_download(artifact, self.cache)

    def test_download_checksum_mismatch_does_not_poison_cache(self):
        original = self.root / 'source.task'
        original.write_bytes(b'wrong bytes')
        artifact = {'filename': 'download.task', 'url': original.as_uri(), 'sha256': '0' * 64}
        with self.assertRaisesRegex(ValueError, 'SHA-256 mismatch'):
            checked_download(artifact, self.cache)
        self.assertEqual(list(self.cache.iterdir()), [])

    def test_archive_rejects_traversal_and_links(self):
        for name in ['../outside', '/absolute']:
            artifact = self.archive('unsafe', {name: b'invalid'})
            with self.assertRaisesRegex(ValueError, 'Unsafe archive'):
                extract_archive(self.cache / artifact['filename'], self.root / ('extract-' + str(len(name))))
        path = self.cache / 'link.tar.gz'
        with tarfile.open(path, 'w:gz') as archive:
            info = tarfile.TarInfo('link')
            info.type = tarfile.SYMTYPE
            info.linkname = '../outside'
            archive.addfile(info)
        with self.assertRaisesRegex(ValueError, 'Unsafe archive'):
            extract_archive(path, self.root / 'link-extract')
        self.assertFalse((self.root / 'outside').exists())

    def test_offline_install_retains_notices_and_repairs_changed_outputs_from_verified_cache(self):
        artifacts = [self.archive(name, {'LICENSE': b'license', 'NOTICE': b'notice', 'frameworks/binary': b'library'})
                     for name in ['MediaPipeTasksCommon', 'MediaPipeTasksVision']]
        model = self.cache / 'pose_landmarker_full.task'
        model.write_bytes(b'model')
        artifacts.append({'name': 'model', 'filename': model.name, 'url': 'https://invalid.invalid/unused',
                          'sha256': sha256(model)})
        lock = self.root / 'lock.json'
        lock.write_text(json.dumps({'artifacts': artifacts}))
        destination = self.root / 'installed'
        install(lock, destination, self.cache)
        self.assertEqual((destination / 'Notices' / 'MediaPipe-LICENSE.txt').read_bytes(), b'license')
        (destination / model.name).write_bytes(b'corrupted')
        install(lock, destination, self.cache)
        self.assertEqual((destination / model.name).read_bytes(), b'model')
        install(lock, destination, self.cache)
        self.assertEqual([path for path in self.root.glob('mediapipe-*') if path.is_dir()], [])

    def test_source_snapshot_excludes_generated_dependencies_but_keeps_pins(self):
        ios = self.root / 'ios'
        (ios / 'Dependencies').mkdir(parents=True)
        (ios / 'Dependencies' / 'mediapipe.lock.json').write_text('{}')
        (ios / '.dependencies').mkdir()
        (ios / '.dependencies' / 'binary').write_bytes(b'generated')
        manifest = copy_sources(ios, self.root / 'snapshot')
        self.assertEqual(set(manifest), {'Dependencies/mediapipe.lock.json'})
        self.assertFalse((self.root / 'snapshot' / '.dependencies').exists())

    def test_adapter_identifies_the_pinned_model_and_runtime(self):
        lock = json.loads((ROOT / 'ios/Dependencies/mediapipe.lock.json').read_text())
        source = (ROOT / 'ios/TresFort/Station/StationMediaPipeDetector.swift').read_text()
        self.assertIn('runtimeVersion = "' + lock['runtime_version'] + '"', source)
        self.assertIn('modelIdentifier = "' + lock['model_identifier'] + '"', source)
        model = next(a for a in lock['artifacts'] if a['name'] == 'pose_landmarker_full')
        self.assertIn('modelSHA256 = "' + model['sha256'] + '"', source)

    def test_binary_guard_rejects_uploaders_network_imports_and_missing_runner(self):
        methods = '\n'.join('TaskRunner' + method for method in ['Create', 'Process', 'Close'])
        check_symbols(methods, require_runner=True)
        for bad in ['TasksLogger', 'ClearcutLoggingClient', 'GTMSessionFetcher', '_socket', '_connect',
                    'NSURLSession', 'CFHTTPMessageCreateRequest', 'curl_easy_perform']:
            with self.subTest(symbol=bad), self.assertRaises(ValueError):
                check_symbols(methods + '\n' + bad)
        with self.assertRaisesRegex(ValueError, 'method missing'):
            check_symbols('TaskRunnerCreate', require_runner=True)


if __name__ == '__main__':
    unittest.main()
