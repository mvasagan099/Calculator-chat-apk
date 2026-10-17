import { handleDownloadChatMedia } from "./index.ts";
import { HttpError } from "../_shared/http.ts";
function assert(ok: unknown): asserts ok { if (!ok) throw Error("Assertion failed"); }
const path = "11111111-1111-1111-1111-111111111111/22222222-2222-2222-2222-222222222222/photo.jpg";
function fixture({ allowed = true, expired = false } = {}) {
  let reads = 0;
  const authenticated = async (_request: Request) => ({
    client: { rpc: async () => ({
      data: allowed ? {
        expires_at: new Date(Date.now() + (expired ? -60000 : 60000)).toISOString(),
      } : null,
      error: allowed ? null : new Error("denied"),
    }) },
    admin: { storage: { from: () => ({ download: async () => {
      reads++;
      return {
        data: new Blob([new Uint8Array([255, 216, 255, 0])], { type: "image/jpeg" }),
        error: null,
      };
    } }) } },
  });
  return {
    reads: () => reads,
    deps: { authenticated: authenticated as never, body: async () => ({ path }) as never },
  };
}
Deno.test("valid approved media downloads after checking deadline", async () => {
  const f = fixture();
  const result = await handleDownloadChatMedia(
    new Request("https://fixture.invalid", { method: "POST" }), f.deps,
  );
  assert(result.status === 200 && result.headers.get("cache-control")?.includes("no-store"));
  assert((await result.arrayBuffer()).byteLength === 4 && f.reads() === 1);
});
Deno.test("denied or expired media cannot trigger privileged Storage reads", async () => {
  for (const options of [{ allowed: false }, { expired: true }]) {
    const f = fixture(options);
    try {
      await handleDownloadChatMedia(
        new Request("https://fixture.invalid", { method: "POST" }), f.deps,
      );
      throw Error("not rejected");
    } catch (error) {
      assert(error instanceof HttpError && error.status === 403);
    }
    assert(f.reads() === 0);
  }
});
Deno.test("malformed path rejected before privileged Storage access", async () => {
  const f = fixture();
  f.deps.body = async () => ({ path: "../unsafe" }) as never;
  try {
    await handleDownloadChatMedia(
      new Request("https://fixture.invalid", { method: "POST" }), f.deps,
    );
    throw Error("not rejected");
  } catch (error) {
    assert(error instanceof HttpError && error.status === 400);
  }
  assert(f.reads() === 0);
});
