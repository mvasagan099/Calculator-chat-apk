"""Real JDK-signed JAR fixtures, never Flutter APK/AAB or owner signing keys."""
import base64
import os
import sys
import hashlib
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('bundle_verify', ROOT/'scripts/verify-aab.py')
bundle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bundle)


@unittest.skipUnless(all(bundle.jdk_tool(name) for name in ['java','keytool','jarsigner']), 'JDK required for actual fixture-signature tests')
class JdkBundleSignatureTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory=tempfile.TemporaryDirectory(prefix='jar-signature-fixture-')
        cls.root=Path(cls.directory.name)
        cls.keystore=cls.root/'fixture.p12'
        cls.jar=cls.root/'signed-fixture.jar'
        cls.password='ephemeral-test-password-only'
        subprocess.run([bundle.jdk_tool('keytool'),'-genkeypair','-alias','fixture','-keyalg','RSA','-keysize','2048','-validity','1','-dname','CN=Unit Test Fixture','-keystore',str(cls.keystore),'-storepass',cls.password],check=True,capture_output=True,timeout=30)
        cert=subprocess.run([bundle.jdk_tool('keytool'),'-exportcert','-alias','fixture','-keystore',str(cls.keystore),'-storepass',cls.password],check=True,capture_output=True,timeout=30).stdout
        cls.fingerprint=hashlib.sha256(cert).hexdigest()
        with zipfile.ZipFile(cls.jar,'w') as archive:
            archive.writestr('fixture.txt','unit fixture content')
        subprocess.run([bundle.jdk_tool('jarsigner'),'-keystore',str(cls.keystore),'-storepass',cls.password,str(cls.jar),'fixture'],check=True,capture_output=True,timeout=30)

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def verify(self,path,fingerprint):
        return subprocess.run([bundle.jdk_tool('java'),str(ROOT/'security/VerifyBundle.java'),str(path),fingerprint],capture_output=True,timeout=30).returncode

    def test_actual_jdk_signature_and_pinned_certificate_pass(self):
        self.assertEqual(self.verify(self.jar,self.fingerprint),0)

    def test_different_certificate_rejected(self):
        self.assertNotEqual(self.verify(self.jar,'a'*64),0)

    def test_appended_unsigned_entry_rejected(self):
        path=self.root/'unsigned-added.jar';path.write_bytes(self.jar.read_bytes())
        with zipfile.ZipFile(path,'a') as archive:archive.writestr('unsigned.txt','untrusted')
        self.assertNotEqual(self.verify(path,self.fingerprint),0)

    def test_tampered_signed_entry_rejected(self):
        path=self.root/'tampered.jar'
        with zipfile.ZipFile(self.jar) as source,zipfile.ZipFile(path,'w') as target:
            for entry in source.infolist():target.writestr(entry,b'changed' if entry.filename=='fixture.txt' else source.read(entry))
        self.assertNotEqual(self.verify(path,self.fingerprint),0)

    def signing_cli(self,expected):
        work=self.root/'signing-work';properties=self.root/'generated.properties'
        env={**os.environ,'PATH':str(Path(bundle.jdk_tool('keytool')).parent)+os.pathsep+os.environ.get('PATH',''),
             'ANDROID_RELEASE_KEYSTORE_B64':base64.b64encode(self.keystore.read_bytes()).decode(),
             'ANDROID_KEY_ALIAS':'fixture','ANDROID_STORE_PASSWORD':self.password,'ANDROID_KEY_PASSWORD':self.password,
             'ANDROID_CERT_SHA256':expected}
        result=subprocess.run([sys.executable,str(ROOT/'scripts/configure-release-signing.py'),'--directory',str(work),'--properties',str(properties)],env=env,capture_output=True,text=True,timeout=30)
        self.assertNotIn(self.password,result.stdout+result.stderr)
        return result,work,properties

    def test_signing_cli_verifies_real_test_certificate_and_cleans_owned_files(self):
        result,work,properties=self.signing_cli(self.fingerprint)
        self.assertEqual(result.returncode,0)
        self.assertTrue(properties.exists())
        cleaned=subprocess.run([sys.executable,str(ROOT/'scripts/configure-release-signing.py'),'--directory',str(work),'--properties',str(properties),'--cleanup'],capture_output=True,timeout=30)
        self.assertEqual(cleaned.returncode,0);self.assertFalse(properties.exists());self.assertEqual(list(work.iterdir()),[])

    def test_signing_cli_rejects_wrong_certificate_without_leaving_key_material(self):
        result,work,properties=self.signing_cli('0'*64)
        self.assertEqual(result.returncode,2);self.assertFalse(properties.exists());self.assertEqual(list(work.iterdir()),[])
