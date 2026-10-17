import pathlib
import unittest
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parents[2]
MAIN = ROOT / "android/app/src/main"
ANDROID = "{http://schemas.android.com/apk/res/android}"

class LauncherAliases(unittest.TestCase):
    def test_exactly_one_default_alias_and_no_activity_launcher(self):
        root = ET.parse(MAIN / "AndroidManifest.xml").getroot()
        app = root.find("application")
        assert app is not None
        activity = next(x for x in app.findall("activity") if x.get(ANDROID+"name") == ".MainActivity")
        self.assertFalse(any(any(a.get(ANDROID+"name") == "android.intent.action.MAIN" for a in f.findall("action")) for f in activity.findall("intent-filter")))
        aliases = app.findall("activity-alias")
        self.assertEqual(len(aliases), 4)
        self.assertEqual(sum(a.get(ANDROID+"enabled") == "true" for a in aliases), 1)
        self.assertTrue(all(a.get(ANDROID+"targetActivity") == ".MainActivity" for a in aliases))
        self.assertTrue(all(a.get(ANDROID+"label") == "Calculator" for a in aliases))
        for a in aliases:
            icon = a.get(ANDROID+"icon")
            path = MAIN / "res/mipmap-anydpi-v26" / (icon.removeprefix("@mipmap/") + ".xml")
            self.assertTrue(path.is_file(), path)
            ET.parse(path)
    def test_switcher_components_match_manifest(self):
        root = ET.parse(MAIN / "AndroidManifest.xml").getroot()
        aliases = {a.get(ANDROID+"name").removeprefix(".") for a in root.find("application").findall("activity-alias")}
        code = (MAIN / "kotlin/app/calculatorspace/calculator_messenger/LauncherIconSwitcher.kt").read_text()
        self.assertEqual(aliases, {"LauncherClassic", "LauncherMidnight", "LauncherGraphite", "LauncherSunrise"})
        for alias in aliases:
            self.assertIn('"'+alias+'"', code)

if __name__ == "__main__": unittest.main()
