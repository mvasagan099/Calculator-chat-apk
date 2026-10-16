"""Exercise the production platform KDF class, not a crypto mock."""
import os
from pathlib import Path
import subprocess
import sys
import unittest


class PlatformPinKdfTest(unittest.TestCase):
    def test_production_jca_matches_independent_v1_vectors(self):
        root = Path(__file__).resolve().parents[2]
        result = subprocess.run(
            [sys.executable, str(root / 'scripts/test-pin-kdf.py')],
            cwd=root, env=os.environ.copy(), capture_output=True, text=True,
            timeout=60,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('PASS: independent v1/JCA compatibility vectors', result.stdout)


if __name__ == '__main__':
    unittest.main()
