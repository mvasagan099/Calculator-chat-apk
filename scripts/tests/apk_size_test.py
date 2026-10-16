"""Synthetic ZIPs test accounting only; these fixtures are not real APKs."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location('apk_size', Path(__file__).parents[1] / 'apk-size-report.py')
size = importlib.util.module_from_spec(spec)
spec.loader.exec_module(size)


class ApkSizeTest(unittest.TestCase):
    def test_strict_limit_and_mixed_abi(self):
        with tempfile.TemporaryDirectory() as directory:
            apk = Path(directory) / 'fixture.apk'
            with zipfile.ZipFile(apk, 'w') as archive:
                archive.writestr('lib/arm64-v8a/libapp.so', b'app')
                archive.writestr('lib/arm64-v8a/libflutter.so', b'engine')
            result = size.inspect(apk, 'arm64-v8a', apk.stat().st_size)
            self.assertFalse(result['under_limit'])
            self.assertTrue(result['abi_valid'])
            self.assertTrue(result['flutter_libraries_present'])
            self.assertEqual(result['bytes'], sum(result['compressed_groups'].values()) + result['zip_overhead_bytes'])
            with zipfile.ZipFile(apk, 'a') as archive:
                archive.writestr('lib/x86_64/libflutter.so', b'extra')
            self.assertFalse(size.inspect(apk, 'arm64-v8a')['abi_valid'])

    def test_missing_engine_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            apk = Path(directory) / 'fixture.apk'
            with zipfile.ZipFile(apk, 'w') as archive:
                archive.writestr('classes.dex', b'fixture')
            result = size.inspect(apk, 'arm64-v8a')
            self.assertFalse(result['flutter_libraries_present'])
            self.assertFalse(result['abi_valid'])
