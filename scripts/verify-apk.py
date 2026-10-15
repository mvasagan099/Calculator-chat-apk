#!/usr/bin/env python3
"""Verify a real APK using Android tools and inspect known secret formats.

A successful pattern scan is limited evidence, not a forensic guarantee.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import zipfile

PACKAGE = 'app.calculatorspace.calculator_messenger'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('apk', type=Path)
    parser.add_argument('--android-sdk', required=True, type=Path)
    parser.add_argument('--output-dir', type=Path, required=True)
    args = parser.parse_args()
    try:
        if not args.apk.is_file() or args.apk.stat().st_size == 0:
            raise ValueError('APK missing or empty')
        tools = args.android_sdk / 'build-tools/36.0.0'
        signature = subprocess.run([str(tools / 'apksigner'), 'verify', '--verbose', '--print-certs', str(args.apk)], check=True, capture_output=True, text=True).stdout
        badging = subprocess.run([str(tools / 'aapt2'), 'dump', 'badging', str(args.apk)], check=True, capture_output=True, text=True).stdout
        if f"package: name='{PACKAGE}'" not in badging or "sdkVersion:'29'" not in badging:
            raise ValueError('Package identity or minimum Android API does not match the project')
        if "launchable-activity:" not in badging:
            raise ValueError('APK has no launchable activity')
        with zipfile.ZipFile(args.apk) as archive:
            for entry in archive.infolist():
                if entry.filename.lower().endswith(('.jks', '.keystore', '/key.properties', '/.env')):
                    raise ValueError('Private configuration file found in APK')
                # Scan streamed chunks with overlap so a token crossing a chunk
                # boundary is also checked without loading every native library.
                tail = b''
                with archive.open(entry) as data:
                    while chunk := data.read(1024 * 1024):
                        block = tail + chunk
                        if re.search(rb'sb_secret_[A-Za-z0-9_-]{20,}|-----BEGIN (?:RSA |EC )?PRIVATE KEY-----\s+[A-Za-z0-9+/=\r\n]{80,}', block):
                            raise ValueError('Known private credential format found in APK')
                        for token in re.findall(rb'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}', block):
                            payload = token.split(b'.')[1]
                            try:
                                claims = json.loads(base64.urlsafe_b64decode(payload + b'=' * (-len(payload) % 4)))
                            except (ValueError, UnicodeError):
                                continue
                            if isinstance(claims, dict) and claims.get('role') == 'service_role':
                                raise ValueError('Privileged Supabase JWT found in APK')
                        tail = block[-16384:]
        digest = hashlib.file_digest(args.apk.open('rb'), 'sha256').hexdigest()
        args.output_dir.mkdir(parents=True, exist_ok=True)
        (args.output_dir / 'apk-metadata.txt').write_text(badging)
        (args.output_dir / 'apk-signature.txt').write_text(signature)
        (args.output_dir / 'app-debug.apk.sha256').write_text(f'{digest}  {args.apk.name}\n')
        print(f'PASS: signed, nonempty APK; package {PACKAGE}; minimum API 29; known secret scan clear')
        print(f'Size: {args.apk.stat().st_size} bytes; SHA-256: {digest}')
        print('Launch and device installation still require a real device/emulator.')
    except (ValueError, OSError, zipfile.BadZipFile, subprocess.CalledProcessError):
        print('APK verification FAILED. Missing artifact, invalid signature/metadata or private credential detected. No credential value was logged.', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
