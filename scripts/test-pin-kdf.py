#!/usr/bin/env python3
"""Cross-check production JCA KDF against independent synthetic v1 vectors.

This uses a desktop JDK, not Android's provider/Keystore. Never reads owner PINs.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    java_home = os.environ.get('JAVA_HOME')
    if not java_home and Path('/workspace/toolchains/jdk21/bin/javac').is_file():
        java_home = '/workspace/toolchains/jdk21'  # Same cloud JDK as scripts/flutterw.
    javac = str(Path(java_home) / 'bin/javac') if java_home else shutil.which('javac')
    java = str(Path(java_home) / 'bin/java') if java_home else shutil.which('java')
    if not javac or not java:
        raise SystemExit('A full JDK is required for native PBKDF2 compatibility checks')
    vectors = json.loads((ROOT / 'test/fixtures/pin_v1_vectors.json').read_text())
    checks = []
    for v in vectors:
        checks.append('check(' + ','.join([json.dumps(v['pin']), json.dumps(v['salt']), str(v['iterations']), json.dumps(v['hash'])]) + ');')
    source = '''import java.util.Base64;
import app.calculatorspace.calculator_messenger.PinKdf;
class PinKdfProbe {
  static void check(String pin, String salt, int count, String expected) throws Exception {
    byte[] bytes = PinKdf.derive(pin, Base64.getDecoder().decode(salt), count);
    if (!Base64.getEncoder().encodeToString(bytes).equals(expected)) throw new AssertionError("KDF mismatch");
  }
  public static void main(String[] args) throws Exception {
    CHECKS
    long[] times = new long[3];
    for (int i=0;i<3;i++) {
      long start=System.nanoTime();
      PinKdf.derive("258012", new byte[32], 600000);
      times[i]=(System.nanoTime()-start)/1000;
    }
    System.out.println("PASS: independent v1/JCA compatibility vectors");
    System.out.println("{\\"scope\\":\\"desktop JDK synthetic, not Android\\",\\"iterations\\":600000,\\"derive_us\\":"+java.util.Arrays.toString(times)+"}");
  }
}'''.replace('CHECKS', '\n'.join(checks))
    with tempfile.TemporaryDirectory(prefix='pin-kdf-') as directory:
        probe = Path(directory) / 'PinKdfProbe.java'
        probe.write_text(source)
        production = ROOT / 'android/app/src/main/java/app/calculatorspace/calculator_messenger/PinKdf.java'
        subprocess.run([javac, '-d', directory, str(production), str(probe)], check=True, capture_output=True)
        subprocess.run([java, '-cp', directory, 'PinKdfProbe'], check=True)


if __name__ == '__main__':
    main()
