#!/usr/bin/env python3
"""Inspect a signed APK with real Android tools; installation is a separate gate.

Known-secret scanning is limited evidence, never a forensic guarantee. Unit ZIP
fixtures test the scanner only and are never presented as installable APKs.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import zipfile

PACKAGE = 'app.calculatorspace.calculator_messenger'


def scan_archive(archive):
    total = 0
    for entry in archive.infolist():
        name = PurePosixPath(entry.filename.replace('\\', '/'))
        if name.is_absolute() or '..' in name.parts or name.name.lower().endswith(('.jks', '.keystore')) or name.name.lower() == 'key.properties' or name.name.lower().startswith('.env'):
            raise ValueError('Private configuration or invalid archive path')
        total += entry.file_size
        if total > 2 * 1024**3 or entry.file_size > 512 * 1024**2:
            raise ValueError('Archive exceeds inspection bounds')
        tail = b''
        with archive.open(entry) as data:
            while chunk := data.read(1024 * 1024):
                block = tail + chunk
                if re.search(rb'sb_secret_[A-Za-z0-9_-]{20,}|-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----(?:\s|\\[rn])+(?:[A-Za-z0-9+/=\r\n\t ]|\\[rn]){80,}', block):
                    raise ValueError('Known private credential format')
                for token in re.findall(rb'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}', block):
                    payload = token.split(b'.')[1]
                    try:
                        claims = json.loads(base64.urlsafe_b64decode(payload + b'=' * (-len(payload) % 4)))
                    except (ValueError, UnicodeError):
                        continue
                    if isinstance(claims, dict) and claims.get('role') == 'service_role':
                        raise ValueError('Privileged Supabase JWT')
                tail = block[-16384:]



def compiled_launcher_alias(tree):
    """Validate the launch intent in aapt2's *compiled* AndroidManifest.xml.

    AAPT2 badging sometimes omits launchable-activity for activity-alias.
    Require exactly one explicitly enabled/exported alias, a real target
    activity, and matching MAIN and LAUNCHER in one intent-filter.
    """
    roots, stack = [], []
    for line in tree.splitlines():
        tag = re.match(r'^(\s*)E:\s+([\w.-]+)\b', line)
        if tag:
            depth = len(tag[1])
            node = {'tag': tag[2], 'attrs': {}, 'children': []}
            while stack and stack[-1][0] >= depth:
                stack.pop()
            if stack:
                stack[-1][1]['children'].append(node)
            else:
                roots.append(node)
            stack.append((depth, node))
        else:
            attr = re.match(r'^\s*A:\s+android:([\w]+)(?:\([^)]*\))?=(.*)
    package = re.search(r"^package: name='([^']+)'", badging, re.MULTILINE)
    # AAPT2 emits minSdkVersion while older aapt emits sdkVersion.
    minimum = re.search(r"^(?:minSdkVersion|sdkVersion):'(\d+)'", badging, re.MULTILINE)
    target_api = re.search(r"^targetSdkVersion:'(\d+)'", badging, re.MULTILINE)
    if not package:
        raise ValueError('Package identifier is missing from aapt2 badging output')
    if package[1] != PACKAGE:
        raise ValueError(f'Package identifier mismatch: expected {PACKAGE}, found {package[1]}')
    if not minimum:
        raise ValueError('Minimum SDK is missing from aapt2 badging output (expected minSdkVersion or sdkVersion)')
    if int(minimum[1]) != 29:
        raise ValueError(f'Minimum SDK mismatch: expected 29, found {minimum[1]}')
    if not target_api:
        raise ValueError('Target SDK is missing from aapt2 badging output')
    if int(target_api[1]) != target:
        raise ValueError(f'Target SDK mismatch: expected {target}, found {target_api[1]}')
    if not re.search(r'^launchable-activity:', badging, re.MULTILINE):
        if not manifest_tree or not compiled_launcher_alias(manifest_tree):
            raise ValueError('No verified launchable activity or alias in compiled Android manifest')
    return {'package': package[1], 'min_sdk': int(minimum[1]), 'target_sdk': int(target_api[1])}


def certificate(signature, variant, expected=None):
    signers = re.findall(r'^Signer #\d+ certificate SHA-256 digest:\s*([0-9a-fA-F]{64})\s*$', signature, re.MULTILINE)
    if len(signers) != 1:
        raise ValueError(f'Expected one APK certificate SHA-256 digest, parsed {len(signers)}')
    actual = signers[0].lower()
    if variant == 'release':
        wanted = (expected or '').replace(':', '').lower()
        if not re.fullmatch('[0-9a-f]{64}', wanted) or actual != wanted or re.search(r'Android Debug', signature, re.IGNORECASE):
            raise ValueError('Release signer does not match owner certificate')
    return actual


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('apk', type=Path)
    parser.add_argument('--android-sdk', required=True, type=Path)
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--variant', choices=['debug', 'profile', 'release'], default='debug')
    parser.add_argument('--expected-cert-sha256')
    parser.add_argument('--target-sdk', type=int, default=36)
    args = parser.parse_args()
    stage = 'APK existence'
    try:
        if not args.apk.is_file() or args.apk.stat().st_size == 0:
            raise ValueError('APK missing or empty')
        tools = args.android_sdk / 'build-tools/36.0.0'
        stage = 'apksigner signature verification'
        signature = subprocess.run([str(tools / 'apksigner'), 'verify', '--verbose', '--print-certs', str(args.apk)], check=True, capture_output=True, text=True, timeout=60).stdout
        stage = 'aapt2 badging extraction'
        badging = subprocess.run([str(tools / 'aapt2'), 'dump', 'badging', str(args.apk)], check=True, capture_output=True, text=True, timeout=60).stdout
        stage = 'package and SDK metadata'
        manifest_tree = None
        if not re.search(r'^launchable-activity:', badging, re.MULTILINE):
            stage = 'compiled launcher alias inspection'
            manifest_tree = subprocess.run(
                [str(tools / 'aapt2'), 'dump', 'xmltree', str(args.apk),
                 '--file', 'AndroidManifest.xml'],
                check=True, capture_output=True, text=True, timeout=60,
            ).stdout
        stage = 'package and SDK metadata'
        result = metadata(badging, args.target_sdk, manifest_tree)
        if manifest_tree is not None:
            result['launcher_alias'] = compiled_launcher_alias(manifest_tree)
        stage = 'signing certificate digest'
        result['certificate_sha256'] = certificate(signature, args.variant, args.expected_cert_sha256)
        stage = 'private credential and archive safety scan'
        with zipfile.ZipFile(args.apk) as archive:
            scan_archive(archive)
        stage = 'SHA-256 digest'
        checksum = hashlib.sha256()
        with args.apk.open('rb') as source:
            while chunk := source.read(1024 * 1024):
                checksum.update(chunk)
        digest = checksum.hexdigest()
        result.update({'file': args.apk.name, 'bytes': args.apk.stat().st_size, 'sha256': digest, 'variant': args.variant, 'classification': 'development', 'installation': 'NOT TESTED', 'hosted_services': 'NOT TESTED'})
        stage = 'inspection evidence output'
        args.output_dir.mkdir(parents=True, exist_ok=True)
        (args.output_dir / 'apk-metadata.txt').write_text(badging)
        (args.output_dir / 'apk-signature.txt').write_text(signature)
        (args.output_dir / 'artifact-inspection.json').write_text(json.dumps(result, indent=2) + '\n')
        (args.output_dir / (args.apk.name + '.sha256')).write_text(f'{digest}  {args.apk.name}\n')
        print(f'PASS: signed, nonempty APK; package {PACKAGE}; API 29/{args.target_sdk}; known secret scan clear')
        print(f'Size: {args.apk.stat().st_size} bytes; SHA-256: {digest}')
        print('Installation, launch and provider behavior remain unverified.')
    except ValueError as exc:
        # Only print our own fixed-format validation errors: no APK data or secrets.
        print(f'APK inspection FAILED at {stage}: {exc}', file=sys.stderr)
        return 1
    except subprocess.CalledProcessError as exc:
        # Never echo tool stdout/stderr or environment variables in CI logs.
        print(f'APK inspection FAILED at {stage}: Android tool exit code {exc.returncode}', file=sys.stderr)
        return 1
    except (OSError, zipfile.BadZipFile, subprocess.TimeoutExpired) as exc:
        print(f'APK inspection FAILED at {stage}: {type(exc).__name__}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
, line)
            if attr and stack:
                stack[-1][1]['attrs'][attr[1]] = attr[2]
    def string(node, name):
        raw = node['attrs'].get(name, '')
        matched = re.search(r'"([^"]+)"', raw)
        return matched[1] if matched else ''
    def enabled(node, name):
        raw = node['attrs'].get(name, '')
        return bool(re.search(r'0xffffffff|0x00000001|\btrue\b', raw, re.I))
    apps = [n for root in roots for n in root['children'] if n['tag'] == 'application']
    if len(apps) != 1:
        return None
    main = PACKAGE + '.MainActivity'
    if not any(n['tag'] == 'activity' and string(n, 'name') in (main, '.MainActivity')
               for n in apps[0]['children']):
        return None
    launches = []
    for alias in apps[0]['children']:
        if alias['tag'] != 'activity-alias' or not enabled(alias, 'enabled') or not enabled(alias, 'exported'):
            continue
        if string(alias, 'targetActivity') not in (main, '.MainActivity'):
            continue
        for intent in alias['children']:
            if intent['tag'] != 'intent-filter':
                continue
            actions = {string(n, 'name') for n in intent['children'] if n['tag'] == 'action'}
            categories = {string(n, 'name') for n in intent['children'] if n['tag'] == 'category'}
            if 'android.intent.action.MAIN' in actions and 'android.intent.category.LAUNCHER' in categories:
                launches.append(string(alias, 'name'))
                break
    return launches[0] if len(launches) == 1 else None

def metadata(badging, target, manifest_tree=None):
    package = re.search(r"^package: name='([^']+)'", badging, re.MULTILINE)
    # AAPT2 emits minSdkVersion while older aapt emits sdkVersion.
    minimum = re.search(r"^(?:minSdkVersion|sdkVersion):'(\d+)'", badging, re.MULTILINE)
    target_api = re.search(r"^targetSdkVersion:'(\d+)'", badging, re.MULTILINE)
    if not package:
        raise ValueError('Package identifier is missing from aapt2 badging output')
    if package[1] != PACKAGE:
        raise ValueError(f'Package identifier mismatch: expected {PACKAGE}, found {package[1]}')
    if not minimum:
        raise ValueError('Minimum SDK is missing from aapt2 badging output (expected minSdkVersion or sdkVersion)')
    if int(minimum[1]) != 29:
        raise ValueError(f'Minimum SDK mismatch: expected 29, found {minimum[1]}')
    if not target_api:
        raise ValueError('Target SDK is missing from aapt2 badging output')
    if int(target_api[1]) != target:
        raise ValueError(f'Target SDK mismatch: expected {target}, found {target_api[1]}')
    if not re.search(r'^launchable-activity:', badging, re.MULTILINE):
        raise ValueError('No launchable activity in aapt2 badging output')
    return {'package': package[1], 'min_sdk': int(minimum[1]), 'target_sdk': int(target_api[1])}


def certificate(signature, variant, expected=None):
    signers = re.findall(r'^Signer #\d+ certificate SHA-256 digest:\s*([0-9a-fA-F]{64})\s*$', signature, re.MULTILINE)
    if len(signers) != 1:
        raise ValueError(f'Expected one APK certificate SHA-256 digest, parsed {len(signers)}')
    actual = signers[0].lower()
    if variant == 'release':
        wanted = (expected or '').replace(':', '').lower()
        if not re.fullmatch('[0-9a-f]{64}', wanted) or actual != wanted or re.search(r'Android Debug', signature, re.IGNORECASE):
            raise ValueError('Release signer does not match owner certificate')
    return actual


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('apk', type=Path)
    parser.add_argument('--android-sdk', required=True, type=Path)
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--variant', choices=['debug', 'profile', 'release'], default='debug')
    parser.add_argument('--expected-cert-sha256')
    parser.add_argument('--target-sdk', type=int, default=36)
    args = parser.parse_args()
    stage = 'APK existence'
    try:
        if not args.apk.is_file() or args.apk.stat().st_size == 0:
            raise ValueError('APK missing or empty')
        tools = args.android_sdk / 'build-tools/36.0.0'
        stage = 'apksigner signature verification'
        signature = subprocess.run([str(tools / 'apksigner'), 'verify', '--verbose', '--print-certs', str(args.apk)], check=True, capture_output=True, text=True, timeout=60).stdout
        stage = 'aapt2 badging extraction'
        badging = subprocess.run([str(tools / 'aapt2'), 'dump', 'badging', str(args.apk)], check=True, capture_output=True, text=True, timeout=60).stdout
        stage = 'package and SDK metadata'
        result = metadata(badging, args.target_sdk)
        stage = 'signing certificate digest'
        result['certificate_sha256'] = certificate(signature, args.variant, args.expected_cert_sha256)
        stage = 'private credential and archive safety scan'
        with zipfile.ZipFile(args.apk) as archive:
            scan_archive(archive)
        stage = 'SHA-256 digest'
        checksum = hashlib.sha256()
        with args.apk.open('rb') as source:
            while chunk := source.read(1024 * 1024):
                checksum.update(chunk)
        digest = checksum.hexdigest()
        result.update({'file': args.apk.name, 'bytes': args.apk.stat().st_size, 'sha256': digest, 'variant': args.variant, 'classification': 'development', 'installation': 'NOT TESTED', 'hosted_services': 'NOT TESTED'})
        stage = 'inspection evidence output'
        args.output_dir.mkdir(parents=True, exist_ok=True)
        (args.output_dir / 'apk-metadata.txt').write_text(badging)
        (args.output_dir / 'apk-signature.txt').write_text(signature)
        (args.output_dir / 'artifact-inspection.json').write_text(json.dumps(result, indent=2) + '\n')
        (args.output_dir / (args.apk.name + '.sha256')).write_text(f'{digest}  {args.apk.name}\n')
        print(f'PASS: signed, nonempty APK; package {PACKAGE}; API 29/{args.target_sdk}; known secret scan clear')
        print(f'Size: {args.apk.stat().st_size} bytes; SHA-256: {digest}')
        print('Installation, launch and provider behavior remain unverified.')
    except ValueError as exc:
        # Only print our own fixed-format validation errors: no APK data or secrets.
        print(f'APK inspection FAILED at {stage}: {exc}', file=sys.stderr)
        return 1
    except subprocess.CalledProcessError as exc:
        # Never echo tool stdout/stderr or environment variables in CI logs.
        print(f'APK inspection FAILED at {stage}: Android tool exit code {exc.returncode}', file=sys.stderr)
        return 1
    except (OSError, zipfile.BadZipFile, subprocess.TimeoutExpired) as exc:
        print(f'APK inspection FAILED at {stage}: {type(exc).__name__}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
