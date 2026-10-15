#!/usr/bin/env python3
"""Pinned official native-library probe; does not enable Flutter E2EE."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import urllib.parse
import urllib.request

repository = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--cache', type=Path, default=os.environ.get('SIGNAL_PROTOTYPE_CACHE', str(repository / '.dart_tool/signal-prototype')))
options = parser.parse_args()
cache = options.cache
cache.mkdir(parents=True, exist_ok=True)
artifacts = json.loads((repository / 'security/prototype/artifacts.lock.json').read_text())
classpath = []
for item in artifacts:
    url = urllib.parse.urlparse(item['url'])
    if url.scheme != 'https' or url.hostname != 'repo.maven.apache.org' or url.query:
        raise SystemExit('Untrusted artifact source')
    destination = cache / Path(url.path).name
    if not destination.exists() or hashlib.sha256(destination.read_bytes()).hexdigest() != item['sha256']:
        with urllib.request.urlopen(item['url'], timeout=60) as response, destination.open('wb') as output:
            shutil.copyfileobj(response, output)
    if destination.stat().st_size != item['bytes'] or hashlib.sha256(destination.read_bytes()).hexdigest() != item['sha256']:
        raise SystemExit('Artifact integrity verification failed')
    classpath.append(str(destination))
java_home = Path(os.environ.get('JAVA_HOME', '/workspace/toolchains/jdk21'))
javac = str(java_home / 'bin/javac') if (java_home / 'bin/javac').exists() else shutil.which('javac')
java = str(java_home / 'bin/java') if (java_home / 'bin/java').exists() else shutil.which('java')
if not java or not javac:
    raise SystemExit('JDK 21 is required')
classes = cache / 'classes'
if classes.exists():
    shutil.rmtree(classes)
classes.mkdir()
source = repository / 'security/prototype/SignalProtocolProbe.java'
subprocess.run([javac, '-sourcepath', str(source.parent), '-cp', os.pathsep.join(classpath), '-d', str(classes), str(source)], check=True, timeout=120)
subprocess.run([java, '-cp', os.pathsep.join([str(classes), *classpath]), 'SignalProtocolProbe'], check=True, timeout=120)
