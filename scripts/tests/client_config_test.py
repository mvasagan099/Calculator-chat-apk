import base64
import importlib.util
import json
from pathlib import Path
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

    def test_firebase_native_resources_match_public_dart_config(self):
        data, resource = config.prepare(self.connected(), 'connected', self.firebase())
        self.assertEqual(data['FIREBASE_APP_ID'], '1:123456:android:abcdef')
        self.assertIn('name="google_app_id"', resource)
        self.assertIn('name="gcm_defaultSenderId"', resource)
        self.assertNotIn('private_key', resource)

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


if __name__ == '__main__':
    unittest.main()
