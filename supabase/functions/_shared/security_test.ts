import { mediaMatches } from "./media.ts";
import { authenticated, body, HttpError, uuid } from "./http.ts";
function assert(condition: boolean, message = "assertion failed") {
  if (!condition) throw new Error(message);
}
Deno.test("reject unauthenticated function calls before accessing service credentials", async () => {
  try {
    await authenticated(new Request("https://example.test"));
    throw new Error("accepted missing bearer");
  } catch (e) {
    assert(e instanceof HttpError && e.status === 401);
  }
});
Deno.test("reject malformed IDs, body methods, oversized and non-object JSON", async () => {
  for (
    const value of [null, "../secret", "00000000-0000-0000-0000-00000000000x"]
  ) {
    try {
      uuid(value);
      throw new Error("accepted invalid id");
    } catch (e) {
      assert(e instanceof HttpError && e.status === 400);
    }
  }
  for (
    const request of [
      new Request("https://example.test"),
      new Request("https://example.test", { method: "POST", body: "[]" }),
      new Request("https://example.test", {
        method: "POST",
        body: "x".repeat(17000),
      }),
    ]
  ) {
    try {
      await body(request);
      throw new Error("accepted invalid request");
    } catch (e) {
      assert(e instanceof HttpError && [400, 405, 413].includes(e.status));
    }
  }
  assert(uuid("10000000-0000-0000-0000-000000000001").length === 36);
});
Deno.test("attachment byte validation rejects spoofed MIME and executable payloads", () => {
  const executable = new Uint8Array([77, 90, 0, 0, 1, 2, 3, 4]);
  for (
    const mime of [
      "image/jpeg",
      "video/mp4",
      "application/pdf",
      "application/x-executable",
      "application/zip",
    ]
  ) assert(!mediaMatches(executable, mime), mime);
  assert(
    mediaMatches(new TextEncoder().encode("%PDF-1.7\n"), "application/pdf"),
  );
  assert(
    mediaMatches(
      new TextEncoder().encode("BEGIN:VCARD\nVERSION:4.0\nEND:VCARD"),
      "text/vcard",
    ),
  );
  assert(!mediaMatches(new Uint8Array([0, 255, 1]), "text/plain"));
  assert(!mediaMatches(new Uint8Array(26 * 1024 * 1024), "application/pdf"));
});
