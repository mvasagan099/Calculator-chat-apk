import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("apk_verify", Path(__file__).resolve().parents[1] / "verify-apk.py")
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)

PREFIX = ("package: name='app.calculatorspace.calculator_messenger' versionCode='1'\n"
          "sdkVersion:'29'\n"
          "targetSdkVersion:'36'\n")
P = 'app.calculatorspace.calculator_messenger'


def tree(enabled="0xffffffff", exported="0xffffffff", action="android.intent.action.MAIN", target=None):
    return f"""E: manifest (line=1)
  E: application (line=2)
    E: activity (line=3)
      A: android:name(0x01010003)="{P}.MainActivity"
    E: activity-alias (line=4)
      A: android:name(0x01010003)="{P}.LauncherClassic"
      A: android:targetActivity(0x01010202)="{target or P+'.MainActivity'}"
      A: android:enabled(0x0101000e)=(type 0x12){enabled}
      A: android:exported(0x01010010)=(type 0x12){exported}
      E: intent-filter (line=5)
        E: action (line=6)
          A: android:name(0x01010003)="{action}"
        E: category (line=7)
          A: android:name(0x01010003)="android.intent.category.LAUNCHER"
"""


class LauncherAliasVerification(unittest.TestCase):
    def test_launchable_alias_in_compiled_manifest(self):
        self.assertEqual(verify.compiled_launcher_alias(tree()), P+'.LauncherClassic')
        self.assertEqual(verify.metadata(PREFIX, 36, tree())['min_sdk'], 29)

    def test_aapt2_expanded_namespace_launcher_alias(self):
        # aapt2 build-tools 36 emits expanded resource namespace attribute names.
        expanded = tree().replace(
            "A: android:", "A: http://schemas.android.com/apk/res/android:"
        )
        # AAPT2 places the document elements beneath a namespace declaration.
        xml = ("N: android=http://schemas.android.com/apk/res/android (line=1)\n"
               + "\n".join("  " + line for line in expanded.splitlines()) + "\n")
        self.assertEqual(verify.compiled_launcher_alias(xml), P+'.LauncherClassic')
        self.assertEqual(verify.metadata(PREFIX, 36, xml)['target_sdk'], 36)
        for invalid in (xml.replace('0xffffffff', '0x00000000', 1),
                        xml.replace('android.intent.action.MAIN', 'android.intent.action.VIEW')):
            with self.subTest(invalid=invalid[-160:]):
                with self.assertRaises(ValueError):
                    verify.metadata(PREFIX, 36, invalid)

    def test_normal_launcher_in_badging_still_works(self):
        self.assertEqual(verify.metadata(PREFIX+"launchable-activity: name='.MainActivity'\n",36)['package'], P)

    def test_missing_invalid_disabled_unexported_aliases_are_rejected(self):
        invalid = [None, '', tree(enabled='0x00000000'),
                   tree(exported='0x00000000'),
                   tree(action='android.intent.action.VIEW'),
                   tree(target='invalid.BadActivity'),
                   tree()+tree().split('    E: activity-alias')[1].join(['    E: activity-alias',''])]
        for xml in invalid:
            with self.subTest(xml=xml and xml[-100:]):
                with self.assertRaises(ValueError):
                    verify.metadata(PREFIX,36,xml)

    def test_strict_package_and_sdk_checks_remain_enforced(self):
        for badge, target in [(PREFIX.replace(P,'malicious.example'),36),
                              (PREFIX.replace("sdkVersion:'29'","sdkVersion:'28'"),36),
                              (PREFIX,35)]:
            with self.assertRaises(ValueError):
                verify.metadata(badge,target,tree())


if __name__ == '__main__':
    unittest.main()
