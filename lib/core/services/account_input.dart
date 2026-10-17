// Shared form validation; passwords never become model fields or persisted data.
class AccountInput {
  static String userId(String value) {
    final id = value.trim();
    if (!RegExp(r'^[a-z0-9_]{3,30}$').hasMatch(id)) {
      throw const FormatException(
        'Use 3–30 lowercase letters, numbers or underscores for User ID.',
      );
    }
    return id;
  }

  static String username(String value) => userId(value);

  static String displayName(String value) {
    final name = value.trim();
    if (name.isEmpty || name.runes.length > 80) {
      throw const FormatException('Display name must contain 1–80 characters.');
    }
    return name;
  }

  // Unverified: not sufficient for password reset without SMS ownership proof.
  static String? recoveryPhone(String value) {
    final phone = value.replaceAll(RegExp(r'[\s()-]'), '');
    if (phone.isEmpty) return null;
    if (!RegExp(r'^\+[1-9][0-9]{7,14}$').hasMatch(phone)) {
      throw const FormatException(
        'Enter a mobile number with country code, e.g. +919876543210.',
      );
    }
    return phone;
  }

  static void password(String value, String confirmation) {
    if (value.runes.length < 12 || value.length > 256) {
      throw const FormatException('Use a password of 12–256 characters.');
    }
    if (value != confirmation) {
      throw const FormatException('Passwords do not match.');
    }
  }
}
