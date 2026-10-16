"""Inspection fixtures only: these ZIPs are not APKs or deployable bundles."""
import base64
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
import zipfile

SCRIPTS = Path(__file__).resolve().parents[1]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


apk = load('apk', 'verify-apk.py')
signing = load('signing', 'configure-release-signing.py')


def scan(files):
    data = io.BytesIO()
    with zipfile.ZipFile(data, 'w') as archive:
        for name, value in files.items():
            archive.writestr(name, value)
    data.seek(0)
    with zipfile.ZipFile(data) as archive:
        apk.scan_archive(archive)


class ReleaseArtifactToolTest(unittest.TestCase):
    def test_public_identifiers_and_ordinary_assets_are_allowed(self):
        scan({'assets/app.txt': 'Calculator Messenger; sb_publishable_public_unit_test_value'})

    def test_root_and_nested_private_files_are_rejected(self):
        for name in ['key.properties', 'assets/key.properties', '.env', 'assets/.env.production', 'release.jks', 'assets/key.keystore', '../escape', '/absolute']:
            with self.subTest(name=name), self.assertRaises(ValueError):
                scan({name: 'private fixture'})

    def test_privileged_jwt_crossing_chunk_boundary_is_rejected(self):
        payload = base64.urlsafe_b64encode(b'{"role":"service_role"}').rstrip(b'=')
        token = b'eyJhbGciOiJIUzI1NiJ9.' + payload + b'.notARealSignature000'
        with self.assertRaises(ValueError):
            scan({'lib/native.so': b'x' * (1024*1024-10) + token})

    def test_private_key_json_escaping_and_secret_key_are_rejected(self):
        for value in [b'sb_secret_' + b'a'*32, b'-----BEGIN PRIVATE KEY-----\\n' + b'A'*100, b'-----BEGIN OPENSSH PRIVATE KEY-----\n' + b'A'*100]:
            with self.subTest(value=value[:15]), self.assertRaises(ValueError):
                scan({'assets/input.txt': value})

    def test_parser_literal_is_not_misidentified_as_private_key_material(self):
        scan({'lib/parser.so': b'-----BEGIN PRIVATE KEY-----\x00parse error'})

    def test_package_target_minimum_and_launch_metadata(self):
        valid = f"package: name='{apk.PACKAGE}' versionCode='1'\nsdkVersion:'29'\ntargetSdkVersion:'36'\nlaunchable-activity: name='MainActivity'\n"
        self.assertEqual(apk.metadata(valid, 36)['min_sdk'], 29)
        for invalid in [valid.replace(apk.PACKAGE, 'wrong.package'), valid.replace("sdkVersion:'29'", "sdkVersion:'28'"), valid.replace("targetSdkVersion:'36'", "targetSdkVersion:'35'"), valid.replace('launchable-activity:', 'not-launchable:')]:
            with self.assertRaises(ValueError):
                apk.metadata(invalid, 36)

    def test_aapt2_minimum_sdk_metadata_format(self):
        badging = (
            f"package: name='{apk.PACKAGE}' versionCode='1'\\n"
            "minSdkVersion:'29'\\n"
            "targetSdkVersion:'36'\\n"
            "launchable-activity: name='MainActivity'\\n"
        )
        self.assertEqual(apk.metadata(badging, 36)['min_sdk'], 29)
        with self.assertRaises(ValueError):
            apk.metadata(badging.replace("minSdkVersion:'29'", "minSdkVersion:'28'"), 36)

    def test_release_certificate_must_match_owner_and_not_debug(self):
        fingerprint = 'a'*64
        signature = 'Signer #1 certificate DN: CN=Unit Test\nSigner #1 certificate SHA-256 digest: ' + fingerprint
        self.assertEqual(apk.certificate(signature, 'release', fingerprint), fingerprint)
        for expected in [None, 'invalid', 'b'*64]:
            with self.assertRaises(ValueError):
                apk.certificate(signature, 'release', expected)
        with self.assertRaises(ValueError):
            apk.certificate(signature.replace('Unit Test', 'Android Debug'), 'release', fingerprint)
        with self.assertRaises(ValueError):
            apk.certificate(signature + '\nSigner #2 certificate SHA-256 digest: ' + fingerprint, 'release', fingerprint)


class SigningMaterialTest(unittest.TestCase):
    def values(self):
        # This byte fixture is intentionally NOT a real keystore. The CLI's
        # actual keytool/certificate check is separately required before builds.
        return {'ANDROID_RELEASE_KEYSTORE_B64': base64.b64encode(b'configuration-fixture-not-a-keystore').decode(), 'ANDROID_KEY_ALIAS': 'fixture alias', 'ANDROID_STORE_PASSWORD': 'fixture:with=characters\\and\nnewline', 'ANDROID_KEY_PASSWORD': 'fixture-only', 'ANDROID_CERT_SHA256': 'c'*64}

    def test_missing_inputs_and_malformed_base64_create_nothing(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)
            for values in [{}, {**self.values(), 'ANDROID_RELEASE_KEYSTORE_B64':'invalid$$'}]:
                with self.assertRaises(ValueError):
                    signing.materialize(values, root, root/'key.properties')
            self.assertEqual(list(root.iterdir()), [])

    def test_private_permissions_escaping_and_owned_cleanup(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp); properties=root/'key.properties'
            record, fingerprint=signing.materialize(self.values(), root, properties)
            self.assertEqual(fingerprint, 'c'*64)
            self.assertEqual(properties.stat().st_mode & 0o777, 0o600)
            self.assertEqual(Path(record['keystore']).stat().st_mode & 0o777, 0o600)
            self.assertIn('storePassword=fixture\\:with\\=characters\\\\and\\nnewline', properties.read_text())
            signing.cleanup(record, root, properties)
            self.assertEqual(list(root.iterdir()), [])

    def test_existing_owner_configuration_is_preserved(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp); properties=root/'key.properties';properties.write_text('owner configuration')
            with self.assertRaises(ValueError):
                signing.materialize(self.values(), root, properties)
            self.assertEqual(properties.read_text(), 'owner configuration')
            self.assertEqual(len(list(root.iterdir())),1)

    def test_cleanup_refuses_outside_scope(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)
            with self.assertRaises(ValueError):
                signing.cleanup({'keystore':str(root/'owner.jks'),'properties':str(root/'key.properties')},root,root/'key.properties')

    def test_java_unicode_and_control_characters_are_escaped(self):
        self.assertEqual(signing.java_value('a\tb\r\n'),r'a\tb\r\n')
        self.assertEqual(signing.java_value('₹'),r'\u20b9')
