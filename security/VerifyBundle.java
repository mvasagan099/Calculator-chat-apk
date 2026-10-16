import java.nio.file.Path;
import java.security.CodeSigner;
import java.security.MessageDigest;
import java.security.cert.X509Certificate;
import java.util.HexFormat;
import java.util.jar.JarFile;

/** Standard JDK JAR-signature verification, not application cryptography. */
class VerifyBundle {
  public static void main(String[] args) throws Exception {
    if (args.length != 2 || !args[1].matches("[0-9a-fA-F]{64}"))
      throw new IllegalArgumentException("Bundle and pinned certificate required");
    int count = 0;
    try (var archive = new JarFile(Path.of(args[0]).toFile(), true)) {
      var entries = archive.entries();
      byte[] buffer = new byte[65536];
      while (entries.hasMoreElements()) {
        var entry = entries.nextElement();
        if (entry.isDirectory()) continue;
        String name = entry.getName();
        // Reading every byte causes the JDK to validate manifest entry digests.
        try (var input = archive.getInputStream(entry)) {
          while (input.read(buffer) != -1) {}
        }
        if (name.equalsIgnoreCase("META-INF/MANIFEST.MF") ||
            name.matches("(?i)META-INF/[^/]+\\.(SF|RSA|DSA|EC)")) continue;
        CodeSigner[] signers = entry.getCodeSigners();
        if (signers == null || signers.length != 1)
          throw new SecurityException("Unsigned or multiply signed bundle entry");
        var cert = (X509Certificate) signers[0].getSignerCertPath().getCertificates().getFirst();
        String actual = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(cert.getEncoded()));
        if (!actual.equalsIgnoreCase(args[1]) || cert.getSubjectX500Principal().getName().contains("Android Debug"))
          throw new SecurityException("Unexpected certificate");
        count++;
      }
    }
    if (count == 0) throw new SecurityException("No signed content");
    System.out.println("PASS: standard JDK verified pinned signer for " + count + " content entries");
  }
}
