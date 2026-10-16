package app.calculatorspace.calculator_messenger;

import javax.crypto.SecretKeyFactory;
import javax.crypto.spec.PBEKeySpec;
import java.security.GeneralSecurityException;
import java.util.Arrays;

/** Platform PBKDF2, with the exact ASCII numeric v1 PIN semantics. No storage. */
public final class PinKdf {
    private PinKdf() {}

    public static byte[] derive(String pin, byte[] salt, int iterations) throws GeneralSecurityException {
        if (pin == null || !pin.matches("[0-9]{4,12}") || salt == null || salt.length != 32 || iterations < 1) {
            throw new IllegalArgumentException("Invalid PIN derivation input");
        }
        char[] password = pin.toCharArray();
        PBEKeySpec spec = new PBEKeySpec(password, salt, iterations, 256);
        Arrays.fill(password, '\0');
        try {
            return SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).getEncoded();
        } finally {
            spec.clearPassword();
        }
    }
}
