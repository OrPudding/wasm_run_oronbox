import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('native_release', Path(__file__).with_name('native_release.py'))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


def elf(machine=183, alignment=16384):
    data = bytearray(120)
    data[:6] = b'\x7fELF\x02\x01'
    for fmt, offset, value in [('H',16,3), ('H',18,machine), ('Q',32,64),
                               ('H',54,56), ('H',56,1), ('I',64,1), ('Q',112,alignment)]:
        struct.pack_into('<' + fmt, data, offset, value)
    return bytes(data)


class ReleaseValidationTest(unittest.TestCase):
    def test_matching_android_library(self):
        release.validate_binary(elf(), 'aarch64-linux-android')

    def test_wrong_android_architecture(self):
        with self.assertRaises(ValueError):
            release.validate_binary(elf(machine=62), 'aarch64-linux-android')

    def test_android_requires_16k_alignment(self):
        with self.assertRaises(ValueError):
            release.validate_binary(elf(alignment=4096), 'aarch64-linux-android')

    def test_renamed_apple_library_is_not_android(self):
        with self.assertRaises(ValueError):
            release.validate_binary(b'\xcf\xfa\xed\xfe' + bytes(116), 'aarch64-linux-android')

    def test_source_fingerprint_ignores_checkout_line_endings(self):
        with tempfile.TemporaryDirectory() as directory:
            package = Path(directory)
            (package / 'native/src').mkdir(parents=True)
            (package / 'native/locks').mkdir()
            (package / 'native_release.json').write_bytes(b'{"tag":"test"}\n')
            source = package / 'native/src/lib.rs'
            source.write_bytes(b'fn main() {\n}\n')
            with patch.object(release, 'PACKAGE', package):
                original = release.fingerprint()
                for path in release.source_files():
                    path.write_bytes(path.read_bytes().replace(b'\n', b'\r\n'))
                self.assertEqual(original, release.fingerprint())
                source.write_bytes(b'fn changed() {\r\n}\r\n')
                self.assertNotEqual(original, release.fingerprint())

    def test_partial_matrix_cannot_publish(self):
        with tempfile.TemporaryDirectory() as directory, self.assertRaises(ValueError):
            release.manifest(Path(directory), 'wasm_run-v0.2.0-ob-patch.1')


if __name__ == '__main__':
    unittest.main()
