"""Asset gates must reject corruption and source drift even under python -O."""
from pathlib import Path
import struct
import sys
import tempfile
import unittest
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from app_store_assets import validate_png
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


if __name__ == '__main__':
    unittest.main()
