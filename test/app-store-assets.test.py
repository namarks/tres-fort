"""Asset gates must reject corruption and source drift even under python -O."""
from pathlib import Path
import os
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from app_store_assets import screenshot_dimensions, validate_png
from ios_sources import copy_sources, require_unchanged_sources, source_manifest


def chunk(kind, payload=b''):
    return struct.pack('>I', len(payload)) + kind + payload + struct.pack('>I', zlib.crc32(kind + payload))


class AssetValidationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.signature = b'\x89PNG\r\n\x1a\n'
        cls.header = chunk(b'IHDR', struct.pack('>IIBBBBB', 1206, 2622, 8, 2, 0, 0, 0))
        cls.pixels = bytes((1 + 1206 * 3) * 2622)
        cls.image = chunk(b'IDAT', zlib.compress(cls.pixels))
        cls.end = chunk(b'IEND')
        cls.valid = cls.signature + cls.header + cls.image + cls.end

    def test_accepts_a_complete_opaque_rgb_image(self):
        validate_png(self.valid)

    def test_ipad_capture_is_portrait_and_validator_accepts_known_orientations(self):
        iphone = screenshot_dimensions('iphone')
        ipad = screenshot_dimensions('ipad')
        self.assertEqual(len(iphone), 5)
        self.assertEqual(set(iphone.values()), {(1206, 2622)})
        self.assertEqual(set(ipad), set(iphone) | {'06-station.png'})
        self.assertEqual({ipad[name] for name in iphone}, {(2064, 2752)})
        self.assertEqual(ipad['06-station.png'], (2064, 2752))
        with self.assertRaises(ValueError): screenshot_dimensions('unknown')
        for dimensions in ((2064, 2752), (2752, 2064)):
            width, height = dimensions
            header = chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
            image = self.signature + header + chunk(b'IDAT', zlib.compress(bytes((1 + width * 3) * height))) + self.end
            validate_png(image, dimensions)
            with self.assertRaises(ValueError): validate_png(image)
            with self.assertRaises(ValueError): validate_png(image, dimensions[::-1])
            with self.assertRaises(ValueError):
                validate_png(self.signature + header + self.image + self.end, dimensions)

    def test_capture_rejects_deprecated_flag_and_invalid_device_before_tools_run(self):
        script = Path(__file__).resolve().parents[1] / 'scripts/capture-app-store-screenshots.sh'
        with tempfile.TemporaryDirectory(prefix='tres-fort-capture-contract-') as temporary:
            output = Path(temporary) / 'output'
            for legacy in ('', '0', '1'):
                env = dict(os.environ, APP_STORE_IPHONE_ONLY=legacy, APP_STORE_BUILD='1')
                result = subprocess.run(['bash', str(script), str(output), 'ipad'],
                                        env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 2)
                self.assertIn('APP_STORE_IPHONE_ONLY is obsolete', result.stderr)
                self.assertFalse(output.exists())
            env = dict(os.environ)
            env.pop('APP_STORE_IPHONE_ONLY', None)
            for mode in ('', 'yes'):
                env['APP_STORE_BUILD'] = mode
                result = subprocess.run(['bash', str(script), str(output), 'ipad'],
                                        env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 2)
                self.assertIn('APP_STORE_BUILD must be 0 or 1', result.stderr)
                self.assertFalse(output.exists())
            env.pop('APP_STORE_BUILD', None)
            result = subprocess.run(['bash', str(script), str(output), 'unknown'],
                                    env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertFalse(output.exists())

    def test_rejects_changed_pixel_payload_with_original_checksum(self):
        broken = bytearray(self.image)
        broken[10] ^= 1
        with self.assertRaisesRegex(ValueError, 'checksum'):
            validate_png(self.signature + self.header + broken + self.end)

    def test_requires_header_end_and_consecutive_image_data(self):
        invalid = [self.signature + self.image + self.end,
                   self.signature + self.header + self.image,
                   self.valid + bytes(1),
                   self.signature + self.header + self.header + self.image + self.end,
                   self.signature + self.header + self.image + chunk(b'tEXt', b'k\0v') + self.image + self.end]
        for data in invalid:
            with self.subTest(size=len(data)), self.assertRaises(ValueError):
                validate_png(data)

    def test_rejects_transparency_and_wrong_dimensions_with_valid_checksums(self):
        small = chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 2, 0, 0, 0))
        with self.assertRaisesRegex(ValueError, 'actual IHDR width=1, height=1, bit_depth=8, color_type=2, compression=0, filter=0, interlace=0'):
            validate_png(self.signature + small + self.image + self.end)
        invalid = [self.signature + small + self.image + self.end,
                   self.signature + self.header + chunk(b'tRNS', bytes(6)) + self.image + self.end]
        for data in invalid:
            with self.subTest(size=len(data)), self.assertRaises(ValueError):
                validate_png(data)

    def test_rejects_broken_compression_and_invalid_scanlines_with_valid_checksums(self):
        invalid = [b'not a deflate stream', zlib.compress(bytes([5]) + self.pixels[1:]),
                   zlib.compress(self.pixels[:-1])]
        for data in invalid:
            with self.subTest(size=len(data)), self.assertRaises((ValueError, zlib.error)):
                validate_png(self.signature + self.header + chunk(b'IDAT', data) + self.end)

    def test_copied_source_set_rejects_addition_modification_and_deletion(self):
        with tempfile.TemporaryDirectory(prefix='tres-fort-source-test-') as temporary:
            root = Path(temporary); source = root / 'ios'; source.mkdir()
            original = source / 'App.swift'; original.write_text('original')
            ignored = source / 'Generated.xcodeproj'; ignored.mkdir()
            (ignored / 'generated').write_text('not an input')
            captured = copy_sources(source, root / 'copy')
            self.assertEqual(set(captured), {'App.swift'})
            require_unchanged_sources(source, captured)
            added = source / 'New.swift'; added.write_text('added')
            with self.assertRaises(ValueError): require_unchanged_sources(source, captured)
            added.unlink(); original.write_text('modified')
            with self.assertRaises(ValueError): require_unchanged_sources(source, captured)
            original.unlink()
            with self.assertRaises(ValueError): require_unchanged_sources(source, captured)

    def test_source_snapshot_rejects_links_without_reading_targets(self):
        with tempfile.TemporaryDirectory(prefix='tres-fort-source-test-') as temporary:
            root = Path(temporary); source = root / 'ios'; source.mkdir()
            (source / 'loop').symlink_to(source, target_is_directory=True)
            with self.assertRaises(ValueError): source_manifest(source)


class CaptureFailureRetentionTests(unittest.TestCase):
    def setUp(self):
        import shutil
        temporary = tempfile.TemporaryDirectory(prefix='tres-fort-capture-retention-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.repo = self.root / 'repo'
        scripts = self.repo / 'scripts'
        scripts.mkdir(parents=True)
        (self.repo / 'ios').mkdir()
        source = Path(__file__).resolve().parents[1] / 'scripts'
        for name in ('capture-app-store-screenshots.sh', 'app_store_assets.py', 'ios_sources.py'):
            shutil.copy2(source / name, scripts / name)
        (scripts / 'verify-ios.sh').write_text('''#!/usr/bin/env bash
set -euo pipefail
echo verifier >> "$STUB_TOOL_MARKER"
evidence="$IOS_EVIDENCE_DIR/stub"
mkdir -p "$evidence/Tests.xcresult"
printf '{}\\n' > "$evidence/sources.json"
printf 'retained test result\\n' > "$evidence/Tests.xcresult/result.txt"
printf 'stub xcodebuild evidence\\n' > "$evidence/xcodebuild.log"
echo 'stub verifier output'
if [[ "$CAPTURE_FAILURE_MODE" == verifier ]]; then
  echo 'stub verifier failed' >&2
  exit 7
fi
''')
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.write_tool('git', '''import os, pathlib, sys
with pathlib.Path(os.environ['STUB_TOOL_MARKER']).open('a') as marker:
    marker.write('git\\n')
args = sys.argv[3:]
if args == ['rev-parse', 'HEAD']:
    print('a' * 40)
elif args == ['rev-parse', 'HEAD^{tree}']:
    print('b' * 40)
elif args != ['status', '--porcelain']:
    sys.exit('unexpected git arguments: ' + repr(args))
''')
        self.write_tool('xcrun', '''import json, os, pathlib, struct, sys, zlib
with pathlib.Path(os.environ['STUB_TOOL_MARKER']).open('a') as marker:
    marker.write('xcrun\\n')
args = sys.argv[1:]
if args[:3] != ['xcresulttool', 'export', 'attachments']:
    sys.exit('unexpected xcrun arguments: ' + repr(args))
result = pathlib.Path(args[args.index('--path') + 1])
if not (result / 'result.txt').is_file():
    sys.exit('missing stub test result')
output = pathlib.Path(args[args.index('--output-path') + 1])
output.mkdir(parents=True)
(output / 'partial-export.txt').write_text('partial attachment evidence\\n')
print('stub attachment exporter output', flush=True)
if os.environ['CAPTURE_FAILURE_MODE'] == 'export':
    sys.exit('stub attachment exporter failed')
def chunk(kind, data=b''):
    return (struct.pack('>I', len(data)) + kind + data
            + struct.pack('>I', zlib.crc32(kind + data)))
png = (b'\\x89PNG\\r\\n\\x1a\\n'
       + chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 2, 0, 0, 0))
       + chunk(b'IDAT', zlib.compress(bytes(4))) + chunk(b'IEND'))
(output / 'wrong-size.png').write_bytes(png)
(output / 'manifest.json').write_text(json.dumps([{'attachments': [{
    'suggestedHumanReadableName': 'app-store-01-today_0.png',
    'exportedFileName': 'wrong-size.png'}]}]))
''')
        self.scratch_root = self.root / 'tmp'
        self.scratch_root.mkdir()
        self.output = self.root / 'output'
        self.marker = self.root / 'tools-used.txt'

    def write_tool(self, name, source):
        path = self.bin / name
        path.write_text(f'#!{sys.executable}\n' + source)
        path.chmod(0o755)

    def capture(self, failure):
        env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                   TMPDIR=str(self.scratch_root), APP_STORE_BUILD='1',
                   CAPTURE_FAILURE_MODE=failure, STUB_TOOL_MARKER=str(self.marker))
        env.pop('APP_STORE_IPHONE_ONLY', None)
        return subprocess.run(
            ['bash', str(self.repo / 'scripts/capture-app-store-screenshots.sh'),
             str(self.output)], cwd=self.repo, env=env, capture_output=True,
            text=True, timeout=20)

    def assert_retained_failure(self, result):
        import json
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        retained = self.output / 'failed-capture'
        self.assertTrue(retained.is_dir(), result.stdout + result.stderr)
        evidence = retained / 'results/stub'
        self.assertEqual((evidence / 'Tests.xcresult/result.txt').read_text(),
                         'retained test result\n')
        self.assertEqual((evidence / 'xcodebuild.log').read_text(), 'stub xcodebuild evidence\n')
        self.assertEqual(json.loads((evidence / 'sources.json').read_text()), {})
        self.assertEqual(json.loads((retained / 'source-identity.json').read_text()), {
            'source_head': 'a' * 40, 'source_tree': 'b' * 40, 'working_tree_changes': ''})
        self.assertIn('stub verifier output', (retained / 'verify.log').read_text())
        self.assertEqual(list(self.scratch_root.glob('tres-fort-app-store-capture.*')), [])
        self.assertFalse((self.output / 'manifest.json').exists())
        return retained

    def test_validation_failure_retains_exported_assets_and_test_evidence(self):
        import json
        retained = self.assert_retained_failure(self.capture('validation'))
        attachments = retained / 'attachments'
        self.assertEqual((attachments / 'wrong-size.png').read_bytes()[:8],
                         b'\x89PNG\r\n\x1a\n')
        manifest = json.loads((attachments / 'manifest.json').read_text())
        self.assertEqual(manifest[0]['attachments'][0]['exportedFileName'], 'wrong-size.png')
        self.assertIn('stub attachment exporter output', (retained / 'export.log').read_text())
        self.assertIn('ValueError', (retained / 'validation.log').read_text())

    def test_export_failure_retains_partial_attachments_and_test_evidence(self):
        retained = self.assert_retained_failure(self.capture('export'))
        self.assertEqual((retained / 'attachments/partial-export.txt').read_text(),
                         'partial attachment evidence\n')
        self.assertIn('stub attachment exporter failed', (retained / 'export.log').read_text())
        self.assertFalse((retained / 'attachments/manifest.json').exists())

    def test_verifier_failure_retains_result_bundle_and_build_logs(self):
        retained = self.assert_retained_failure(self.capture('verifier'))
        self.assertIn('stub verifier failed', (retained / 'verify.log').read_text())
        self.assertNotIn('xcrun', self.marker.read_text())

    def test_preexisting_output_is_unchanged_and_no_tools_run(self):
        self.output.mkdir()
        original = b'existing screenshot evidence\x00\xff'
        (self.output / 'keep.png').write_bytes(original)
        result = self.capture('validation')
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertEqual(list(self.output.iterdir()), [self.output / 'keep.png'])
        self.assertEqual((self.output / 'keep.png').read_bytes(), original)
        self.assertFalse(self.marker.exists())
        self.assertEqual(list(self.scratch_root.iterdir()), [])


if __name__ == '__main__':
    unittest.main()
