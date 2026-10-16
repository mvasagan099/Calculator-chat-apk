#!/usr/bin/env python3
"""Measure actual APK bytes and ZIP contributors; does not certify signing."""
import argparse
import hashlib
import json
from pathlib import Path
import sys
import zipfile


def inspect(path, abi, limit=50_000_000):
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        native = [e for e in entries if e.filename.startswith('lib/') and e.filename.endswith('.so')]
        abis = sorted({e.filename.split('/')[1] for e in native})
        libraries = {Path(e.filename).name for e in native}
        groups = {}
        for entry in entries:
            name = entry.filename
            group = ('native/' + name.split('/')[1] if name.startswith('lib/') else
                     'flutter-assets' if name.startswith('assets/flutter_assets/') else
                     'dex' if name.endswith('.dex') else 'other')
            groups[group] = groups.get(group, 0) + entry.compress_size
        size = path.stat().st_size
        checksum = hashlib.sha256()
        with path.open('rb') as source:
            while chunk := source.read(1024 * 1024):
                checksum.update(chunk)
        digest = checksum.hexdigest()
        return {
            'file': str(path), 'bytes': size, 'limit_bytes': limit,
            'under_limit': size < limit, 'expected_abi': abi, 'abis': abis,
            'abi_valid': abis == [abi],
            'flutter_libraries_present': {'libflutter.so', 'libapp.so'} <= libraries,
            'sha256': digest, 'compressed_groups': groups,
            'zip_overhead_bytes': size - sum(e.compress_size for e in entries),
            'largest_entries': [dict(name=e.filename, compressed_bytes=e.compress_size,
                                     uncompressed_bytes=e.file_size)
                                for e in sorted(entries, key=lambda e: e.compress_size, reverse=True)[:25]],
            'signature_and_services': 'NOT VERIFIED by size inspection',
        }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('apk', type=Path)
    parser.add_argument('--abi', required=True, choices=['arm64-v8a', 'armeabi-v7a', 'x86_64'])
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    try:
        result = inspect(args.apk, args.abi)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2) + '\n')
        args.apk.with_suffix('.apk.sha256').write_text(f"{result['sha256']}  {args.apk.name}\n")
        print(f"{args.apk.name}: {result['bytes']} bytes; ABIs: {result['abis']}")
        return 0 if all(result[k] for k in ['under_limit', 'abi_valid', 'flutter_libraries_present']) else 1
    except (OSError, zipfile.BadZipFile):
        print('Size inspection failed: missing or invalid APK', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
