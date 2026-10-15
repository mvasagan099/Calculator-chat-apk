/* Integration probe, not application E2EE. Uses upstream libsignal, never a
 * replacement ratchet/key exchange. In-memory stores are test-only.
 */
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.Arrays;
import javax.crypto.Cipher;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;
import org.signal.libsignal.protocol.*;
import org.signal.libsignal.protocol.ecc.*;
import org.signal.libsignal.protocol.kem.*;
import org.signal.libsignal.protocol.state.*;
import org.signal.libsignal.protocol.state.impl.InMemorySignalProtocolStore;
import org.signal.libsignal.protocol.message.*;
import org.signal.libsignal.protocol.fingerprint.NumericFingerprintGenerator;
import org.signal.libsignal.protocol.util.KeyHelper;

public final class SignalProtocolProbe {
  static int passed;
  static byte[] bytes(String value) { return value.getBytes(StandardCharsets.UTF_8); }
  static void check(boolean condition, String name) {
    if (!condition) throw new AssertionError(name);
    System.out.println("PASS: " + name); passed++;
  }
  interface Action { void run() throws Exception; }
  static void rejects(Class<? extends Exception> expected, Action action, String name) throws Exception {
    try { action.run(); } catch (Exception e) {
      if (!expected.isInstance(e)) throw e;
      check(true, name); return;
    }
    throw new AssertionError(name + " was accepted");
  }
  static final class Device {
    final IdentityKeyPair identity = IdentityKeyPair.generate();
    final InMemorySignalProtocolStore store = new InMemorySignalProtocolStore(identity, KeyHelper.generateRegistrationId(false));
    final SignalProtocolAddress address;
    Device(String user, int device) { address = new SignalProtocolAddress(user, device); }
    PreKeyBundle bundle(int id) {
      var pre = ECKeyPair.generate();
      var signed = ECKeyPair.generate();
      var kyber = KEMKeyPair.generate(KEMKeyType.KYBER_1024);
      var signature = identity.getPrivateKey().calculateSignature(signed.getPublicKey().serialize());
      var kemSignature = identity.getPrivateKey().calculateSignature(kyber.getPublicKey().serialize());
      store.storePreKey(id, new PreKeyRecord(id, pre));
      store.storeSignedPreKey(id, new SignedPreKeyRecord(id, System.currentTimeMillis(), signed, signature));
      store.storeKyberPreKey(id, new KyberPreKeyRecord(id, System.currentTimeMillis(), kyber, kemSignature));
      return new PreKeyBundle(store.getLocalRegistrationId(), address.getDeviceId(), id, pre.getPublicKey(), id,
        signed.getPublicKey(), signature, identity.getPublicKey(), id, kyber.getPublicKey(), kemSignature);
    }
    SessionCipher cipher(Device other) { return new SessionCipher(store, other.address); }
  }
  static byte[] decrypt(SessionCipher cipher, CiphertextMessage message) throws Exception {
    return message.getType() == CiphertextMessage.PREKEY_TYPE
      ? cipher.decrypt(new PreKeySignalMessage(message.serialize()))
      : cipher.decrypt(new SignalMessage(message.serialize()));
  }
  public static void main(String[] args) throws Exception {
    var alice = new Device("alice", 1); var bob = new Device("bob", 1);
    new SessionBuilder(alice.store, bob.address).process(bob.bundle(1));
    var ac = alice.cipher(bob); var bc = bob.cipher(alice);
    var first = ac.encrypt(bytes("initial agreement"));
    check(Arrays.equals(bytes("initial agreement"), decrypt(bc, first)), "native prekey agreement and two-party decryption");
    check(!bob.store.containsPreKey(1), "one-time prekey consumed");
    var response = bc.encrypt(bytes("ratchet response"));
    check(Arrays.equals(bytes("ratchet response"), decrypt(ac, response)), "bidirectional session ratchet");
    var offline1 = ac.encrypt(bytes("offline 1"));
    var offline2 = ac.encrypt(bytes("offline 2"));
    var offline3 = ac.encrypt(bytes("offline 3"));
    check(Arrays.equals(bytes("offline 3"), decrypt(bc, offline3)) &&
      Arrays.equals(bytes("offline 1"), decrypt(bc, offline1)) &&
      Arrays.equals(bytes("offline 2"), decrypt(bc, offline2)), "offline out-of-order delivery");
    rejects(DuplicateMessageException.class, () -> decrypt(bc, offline2), "replay rejected by libsignal");
    var good = ac.encrypt(bytes("authenticated message"));
    var altered = good.serialize().clone(); altered[altered.length - 1] ^= 1;
    rejects(InvalidMessageException.class, () -> bc.decrypt(new SignalMessage(altered)), "ciphertext tampering rejected");
    check(Arrays.equals(bytes("authenticated message"), decrypt(bc, good)), "failed authentication does not consume valid message");
    var delayed = ac.encrypt(bytes("before rotation"));
    new SessionBuilder(alice.store, bob.address).process(bob.bundle(10));
    check(Arrays.equals(bytes("rotated"), decrypt(bc, ac.encrypt(bytes("rotated")))), "signed prekey rotation with the same identity");
    check(Arrays.equals(bytes("before rotation"), decrypt(bc, delayed)), "delayed old-session message after rotation");
    var replacement = new Device("bob", 1);
    rejects(UntrustedIdentityException.class, () -> new SessionBuilder(alice.store, bob.address).process(replacement.bundle(2)), "identity change requires trust decision");
    var generator = new NumericFingerprintGenerator(5200);
    var fingerprint = generator.createFor(2, bytes("alice"), alice.identity.getPublicKey(), bytes("bob"), bob.identity.getPublicKey());
    var changed = generator.createFor(2, bytes("alice"), alice.identity.getPublicKey(), bytes("bob"), replacement.identity.getPublicKey());
    check(!fingerprint.getDisplayableFingerprint().getDisplayText().equals(changed.getDisplayableFingerprint().getDisplayText()), "identity verification number changes");
    var restored = new InMemorySignalProtocolStore(new IdentityKeyPair(alice.identity.serialize()), alice.store.getLocalRegistrationId());
    restored.saveIdentity(bob.address, bob.identity.getPublicKey());
    restored.storeSession(bob.address, new SessionRecord(alice.store.loadSession(bob.address).serialize()));
    var recovered = new SessionCipher(restored, bob.address);
    check(Arrays.equals(bytes("after recovery"), decrypt(bc, recovered.encrypt(bytes("after recovery")))), "serialized session recovery");
    var bob2 = new Device("bob", 2);
    new SessionBuilder(alice.store, bob2.address).process(bob2.bundle(3));
    var secondDevice = alice.cipher(bob2).encrypt(bytes("independent device"));
    check(Arrays.equals(bytes("independent device"), decrypt(bob2.cipher(alice), secondDevice)), "independent recipient-device session");
    rejects(InvalidKeyIdException.class, () -> decrypt(bc, secondDevice), "other device cannot decrypt recipient ciphertext");
    // Standard JCE AES-256-GCM, with the random key transported inside Signal.
    var random = new SecureRandom(); var key = new byte[32]; var nonce = new byte[12];
    random.nextBytes(key); random.nextBytes(nonce);
    var aad = bytes("prototype-v1|conversation|message|attachment");
    var encrypt = Cipher.getInstance("AES/GCM/NoPadding");
    encrypt.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(key,"AES"), new GCMParameterSpec(128,nonce));
    encrypt.updateAAD(aad); var encryptedFile = encrypt.doFinal(bytes("private attachment bytes"));
    var keyPacket = recovered.encrypt(key);
    var receivedKey = decrypt(bc, keyPacket);
    var decrypt = Cipher.getInstance("AES/GCM/NoPadding");
    decrypt.init(Cipher.DECRYPT_MODE, new SecretKeySpec(receivedKey,"AES"), new GCMParameterSpec(128,nonce));
    decrypt.updateAAD(aad);
    check(Arrays.equals(bytes("private attachment bytes"), decrypt.doFinal(encryptedFile)), "attachment key transported through Signal; GCM integrity checked");
    var wrongContext = Cipher.getInstance("AES/GCM/NoPadding");
    wrongContext.init(Cipher.DECRYPT_MODE, new SecretKeySpec(receivedKey,"AES"), new GCMParameterSpec(128,nonce));
    wrongContext.updateAAD(bytes("different message context"));
    rejects(javax.crypto.AEADBadTagException.class, () -> wrongContext.doFinal(encryptedFile), "attachment metadata substitution rejected");
    encryptedFile[0] ^= 1;
    var tampered = Cipher.getInstance("AES/GCM/NoPadding");
    tampered.init(Cipher.DECRYPT_MODE, new SecretKeySpec(receivedKey,"AES"), new GCMParameterSpec(128,nonce));
    tampered.updateAAD(aad);
    rejects(javax.crypto.AEADBadTagException.class, () -> tampered.doFinal(encryptedFile), "attachment tampering rejected");
    Arrays.fill(key,(byte)0); Arrays.fill(receivedKey,(byte)0);
    System.out.println("RESULT: " + passed + " native-library prototype checks passed; app E2EE is NOT enabled");
  }
}
