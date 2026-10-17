// Pure validation/cryptography shared by the handler and executable tests.
export class AccountError extends Error {
  constructor(public status: number, public code: string, message: string) {
    super(message);
  }
}
export function loginId(value: unknown): string {
  if (typeof value !== "string" || !/^[a-z0-9_]{3,30}$/.test(value)) {
    throw new AccountError(400, "invalid_user_id", "Use 3–30 lowercase letters, numbers or underscores.");
  }
  return value;
}
export function accountPassword(value: unknown, confirmation?: unknown): string {
  if (typeof value !== "string" || [...value].length < 12 || value.length > 256) {
    throw new AccountError(400, "weak_password", "Use a password of 12–256 characters.");
  }
  if (confirmation !== undefined && value !== confirmation) {
    throw new AccountError(400, "password_mismatch", "Passwords do not match.");
  }
  return value;
}
export function displayName(value: unknown): string {
  if (typeof value !== "string" || [...value.trim()].length < 1 || [...value.trim()].length > 80) {
    throw new AccountError(400, "invalid_username", "Username must contain 1–80 characters.");
  }
  return value.trim();
}
// Optional contact only. It is not recovery proof until verified by SMS OTP.
export function recoveryPhone(value: unknown): string | null {
  if (value == null || value === "") return null;
  if (typeof value !== "string") {
    throw new AccountError(400, "invalid_mobile", "Invalid mobile number.");
  }
  const normalized = value.replace(/[\\s()-]/g, "");
  if (!/^\\+[1-9][0-9]{7,14}$/.test(normalized)) {
    throw new AccountError(400, "invalid_mobile", "Enter an international mobile number with country code.");
  }
  return normalized;
}
export function newAccountAlias(): string {
  // Server-generated Auth identifier only, never a delivery/recovery address.
  // RFC 6761 reserves .invalid (including subdomains); no domain purchase or
  // another organization's namespace is involved. Existing aliases stay intact.
  return crypto.randomUUID() + "@calculator-messenger.invalid";
}
export function recoveryCode(value: unknown): string {
  if (typeof value !== "string" || !/^[0-9a-f]{64}$/.test(value)) {
    throw new AccountError(401, "invalid_recovery", "User ID or recovery code is invalid.");
  }
  return value;
}
export async function keyedHash(secret: string, context: string, value: string): Promise<string> {
  if (secret.length < 32) throw new Error("Account recovery pepper is not configured");
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(context + "\0" + value));
  return [...new Uint8Array(signature)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
export async function newRecoveryCodes(secret: string) {
  const codes = Array.from({ length: 8 }, () =>
    [...crypto.getRandomValues(new Uint8Array(32))].map((b) => b.toString(16).padStart(2, "0")).join(""));
  return { codes, hashes: await Promise.all(codes.map((code) => keyedHash(secret, "recovery", code))) };
}
