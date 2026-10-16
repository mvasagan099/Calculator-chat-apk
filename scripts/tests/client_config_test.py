import base64
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('client_config', Path(__file__).parents[1] / 'prepare-client-config.py')
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)


def jwt(role):
    payload = base64.urlsafe_b64encode(json.dumps({'role': role}).encode()).decode().rstrip('=')
    return f'eyJhbGciOiJIUzI1NiJ9.{payload}.unitTestSignatureOnly'


class PublicBuildConfigTest(unittest.TestCase):
    def connected(self):
        return {'LOCAL_UI_PREVIEW': False, 'SUPABASE_URL': 'https://staging.supabase.co', 'SUPABASE_ANON_KEY': jwt('anon')}

    def firebase(self, package=config.PACKAGE):
        return {'project_info': {'project_id': 'unit-test-project', 'project_number': '123456'}, 'client': [{'client_info': {'mobilesdk_app_id': '1:123456:android:abcdef', 'android_client_info': {'package_name': package}}, 'api_key': [{'current_key': 'public-unit-test-key'}]}]}

    def test_preview_contains_no_provider_values(self):
        result, resource = config.prepare({}, 'preview')
        self.assertEqual(result, {'LOCAL_UI_PREVIEW': True})
        self.assertIsNone(resource)
        with self.assertRaises(ValueError):
            config.prepare(self.connected(), 'preview')

    def test_real_build_mode_is_explicit(self):
        with self.assertRaises(ValueError):
            config.prepare({'LOCAL_UI_PREVIEW': True}, 'connected')

    def test_legacy_public_anon_key_is_allowed(self):
        result, resource = config.prepare(self.connected(), 'connected')
        self.assertFalse(result['LOCAL_UI_PREVIEW'])
        self.assertIsNone(resource)

    def test_modern_public_key_is_allowed(self):
        data = self.connected()
        data['SUPABASE_ANON_KEY'] = 'sb_publishable_' + 'a' * 30
        config.prepare(data, 'connected')

    def test_service_role_and_secret_keys_are_denied(self):
        for secret in [jwt('service_role'), 'sb_secret_' + 'a' * 30]:
            data = self.connected()
            data['SUPABASE_ANON_KEY'] = secret
            with self.assertRaises(ValueError):
                config.prepare(data, 'connected')

    def test_test_password_or_server_field_cannot_enter_apk(self):
        for field in ['TEST_A_PASSWORD', 'LIVEKIT_API_SECRET', 'SUPABASE_SERVICE_ROLE_KEY', 'FIREBASE_SERVICE_ACCOUNT']:
            data = self.connected()
            data[field] = 'do-not-package'
            with self.assertRaises(ValueError):
                config.prepare(data, 'connected')

    def test_credential_urls_are_denied(self):
        for url in ['http://staging.supabase.co', 'https://user:secret@staging.supabase.co', 'https://staging.supabase.co?key=secret']:
            data = self.connected()
            data['SUPABASE_URL'] = url
            with self.assertRaises(ValueError):
                config.prepare(data, 'connected')

    def test_firebase_console_package_must_match_android(self):
        with self.assertRaises(ValueError):
            config.prepare(self.connected(), 'connected', self.firebase('wrong.package'))

    def test_firebase_console_matches_public_dart_config(self):
        data, resource = config.prepare(self.connected(), 'connected', self.firebase())
        self.assertEqual(data['FIREBASE_APP_ID'], '1:123456:android:abcdef')
        self.assertEqual(resource, self.firebase())
        self.assertEqual(data['FIREBASE_SENDER_ID'], resource['project_info']['project_number'])
        self.assertNotIn('private_key', json.dumps(resource))

    def test_conflicting_firebase_defines_are_denied(self):
        data = self.connected()
        data['FIREBASE_PROJECT_ID'] = 'different-project'
        with self.assertRaises(ValueError):
            config.prepare(data, 'connected', self.firebase())

    def test_firebase_defines_alone_do_not_claim_terminated_delivery(self):
        data = self.connected()
        data['FIREBASE_APP_ID'] = '1:123456:android:abcdef'
        with self.assertRaises(ValueError):
            config.prepare(data, 'connected')

    def run_cli(self, root, firebase, existing=None):
        input_file = root / 'input.json'
        input_file.write_text(json.dumps(self.connected()))
        android_file = root / 'google-services.json'
        if existing is not None:
            android_file.write_text(json.dumps(existing))
        env = {**os.environ, 'FIREBASE_ANDROID_CONFIG': json.dumps(firebase)}
        return subprocess.run([
            sys.executable, str(Path(config.__file__).resolve()),
            '--mode', 'connected', '--input', str(input_file),
            '--output', str(root / 'public.json'),
            '--android-output', str(android_file),
            '--resources', str(root / 'firebase_public.xml'),
        ], env=env, capture_output=True, text=True)

    def test_raw_json_ci_input_installs_console_file_and_retires_old_xml(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            xml = root / 'firebase_public.xml'
            xml.write_text(config.MARKER + '\n<resources/>')
            result = self.run_cli(root, self.firebase())
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads((root / 'google-services.json').read_text()), self.firebase())
            self.assertFalse(xml.exists())
            self.assertEqual(json.loads((root / 'public.json').read_text())['FIREBASE_PROJECT_ID'], 'unit-test-project')
            self.assertNotIn('public-unit-test-key', result.stdout + result.stderr)

    def test_ci_input_does_not_replace_different_owner_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            owner = self.firebase()
            owner['project_info']['project_id'] = 'owner-project'
            result = self.run_cli(root, self.firebase(), existing=owner)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(json.loads((root / 'google-services.json').read_text()), owner)
            self.assertFalse((root / 'public.json').exists())

    def test_service_account_cannot_be_smuggled_into_console_file(self):
        firebase = self.firebase()
        firebase['private_key'] = 'not-a-real-key'
        with self.assertRaises(ValueError):
            config.prepare(self.connected(), 'connected', firebase)

    def test_ci_environment_materializes_exact_android_path(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            env = {k: v for k, v in os.environ.items() if k not in config.PUBLIC_FIELDS}
            env.update({
                'SUPABASE_URL': self.connected()['SUPABASE_URL'],
                'SUPABASE_ANON_KEY': self.connected()['SUPABASE_ANON_KEY'],
                'FIREBASE_ANDROID_CONFIG': json.dumps(self.firebase()),
            })
            result = subprocess.run([
                sys.executable, str(Path(config.__file__).resolve()),
                '--mode', 'connected', '--from-environment',
                '--output', 'config/ci-public.json',
            ], cwd=root, env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads((root / 'android/app/google-services.json').read_text()), self.firebase())
            self.assertFalse((root / 'android/app/src/main/res/values/firebase_public.xml').exists())

    def test_malformed_ci_console_input_fails_without_outputs(self):
        for value in [None, [], {}, {'client': []}, 'base64-is-not-the-required-format']:
            with self.subTest(value=value), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                result = self.run_cli(root, value)
                self.assertEqual(result.returncode, 2)
                self.assertFalse((root / 'google-services.json').exists())
                self.assertFalse((root / 'public.json').exists())


if __name__ == '__main__':
    unittest.main()
