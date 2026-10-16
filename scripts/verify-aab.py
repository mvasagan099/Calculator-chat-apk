#!/usr/bin/env python3
"""Verify AAB archive integrity/owner signature, not Play acceptance or installability."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('apk_inspection', ROOT / 'scripts/verify-apk.py')
apk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(apk)


def jdk_tool(name):
    root = Path(os.environ.get('JAVA_HOME', '/workspace/toolchains/jdk21'))
    candidate = root / 'bin' / name
    return str(candidate) if candidate.exists() else shutil.which(name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle', type=Path)
    parser.add_argument('--expected-cert-sha256', required=True)
    parser.add_argument('--output-dir', required=True, type=Path)
    args = parser.parse_args()
    try:
        expected = args.expected_cert_sha256.replace(':', '').lower()
        if not re.fullmatch('[0-9a-f]{64}', expected) or not args.bundle.is_file() or args.bundle.stat().st_size == 0:
            raise ValueError('Missing bundle/certificate')
        java = jdk_tool('java')
        if not java:
            raise ValueError('JDK 21 required')
        with zipfile.ZipFile(args.bundle) as archive:
            if not {'BundleConfig.pb', 'base/manifest/AndroidManifest.xml'}.issubset(archive.namelist()):
                raise ValueError('Missing Android bundle structure')
            apk.scan_archive(archive)
        result = subprocess.run([java, str(ROOT / 'security/VerifyBundle.java'), str(args.bundle), expected], check=True, capture_output=True, text=True, timeout=120)
        with args.bundle.open('rb') as source:
            digest = hashlib.file_digest(source, 'sha256').hexdigest()
        args.output_dir.mkdir(parents=True, exist_ok=True)
        (args.output_dir / (args.bundle.name + '.sha256')).write_text(f'{digest}  {args.bundle.name}\n')
        (args.output_dir / 'aab-signature.txt').write_text(result.stdout)
        (args.output_dir / 'bundle-inspection.json').write_text(json.dumps({
            'file': args.bundle.name, 'bytes': args.bundle.stat().st_size, 'sha256': digest,
            'certificate_sha256': expected, 'classification': 'development',
            'bundle_manifest_metadata': 'NOT TESTED; inspect with official bundletool',
            'installation': 'NOT TESTED; AAB is not directly installable', 'play_acceptance': 'NOT TESTED',
        }, indent=2) + '\n')
        print('PASS: nonempty signed bundle, pinned owner certificate, known secret scan clear. Manifest metadata, generated APK installation and Play acceptance remain unverified.')
        return 0
    except (ValueError, OSError, zipfile.BadZipFile, subprocess.SubprocessError):
        print('Bundle inspection FAILED. Check archive, owner signature, JDK and private configuration; no values were logged.', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
