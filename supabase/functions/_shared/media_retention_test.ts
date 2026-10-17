import { mediaMatches } from "./media.ts";
function assert(value: boolean) {
  if (!value) throw new Error("MP4 classification failed");
}
function box(type: string, ...payloads: Uint8Array[]) {
  const size = 8 + payloads.reduce((n, p) => n + p.length, 0);
  const bytes = new Uint8Array(size);
  new DataView(bytes.buffer).setUint32(0, size);
  bytes.set(new TextEncoder().encode(type), 4);
  let offset = 8;
  for (const p of payloads) {
    bytes.set(p, offset);
    offset += p.length;
  }
  return bytes;
}
function fixture(...handlers: string[]) {
  const ftyp = box("ftyp", new TextEncoder().encode("isom0000"));
  const moov = box(
    "moov",
    ...handlers.map((handler) =>
      box(
        "trak",
        box(
          "mdia",
          box("hdlr", new Uint8Array(8), new TextEncoder().encode(handler)),
        ),
      )
    ),
  );
  const bytes = new Uint8Array(ftyp.length + moov.length);
  bytes.set(ftyp);
  bytes.set(moov, ftyp.length);
  return bytes;
}
Deno.test("audio-only MP4 retains its audio policy", () => {
  assert(mediaMatches(fixture("soun"), "audio/mp4"));
  assert(!mediaMatches(fixture("soun"), "video/mp4"));
});
Deno.test("video renamed M4A cannot evade visual retention", () => {
  assert(mediaMatches(fixture("vide", "soun"), "video/mp4"));
  assert(!mediaMatches(fixture("vide", "soun"), "audio/mp4"));
});
Deno.test("video-only MP4 is visual media", () => {
  assert(mediaMatches(fixture("vide"), "video/mp4"));
  assert(!mediaMatches(fixture("vide"), "audio/mp4"));
});
Deno.test("truncated MP4 containers fail closed", () => {
  const bytes = fixture("soun");
  assert(!mediaMatches(bytes.subarray(0, bytes.length - 1), "audio/mp4"));
});
Deno.test("forged handler text in compressed media is not a track", () => {
  const bytes = box("ftyp", new TextEncoder().encode("sounvidehdlr"));
  assert(!mediaMatches(bytes, "audio/mp4"));
});
