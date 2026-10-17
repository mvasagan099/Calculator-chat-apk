const ascii = (bytes: Uint8Array, start: number, n: number) =>
  String.fromCharCode(...bytes.subarray(start, start + n));
export function mediaMatches(bytes: Uint8Array, mime: string): boolean {
  if (bytes.length < 1 || bytes.length > 25 * 1024 * 1024) return false;
  switch (mime) {
    case "image/jpeg":
      return bytes[0] === 255 && bytes[1] === 216 && bytes[2] === 255;
    case "image/png":
      return bytes[0] === 137 && ascii(bytes, 1, 3) === "PNG";
    case "image/webp":
      return ascii(bytes, 0, 4) === "RIFF" && ascii(bytes, 8, 4) === "WEBP";
    case "video/mp4":
    case "audio/mp4": {
      if (ascii(bytes, 4, 4) !== "ftyp") return false;
      const tracks = mp4Tracks(bytes);
      return mime === "video/mp4"
        ? tracks.video
        : tracks.audio && !tracks.video;
    }
    case "audio/mpeg":
      return ascii(bytes, 0, 3) === "ID3" ||
        (bytes[0] === 255 && (bytes[1] & 224) === 224);
    case "audio/aac":
      return bytes[0] === 255 && (bytes[1] & 246) === 240;
    case "audio/ogg":
      return ascii(bytes, 0, 4) === "OggS";
    case "application/pdf":
      return ascii(bytes, 0, 5) === "%PDF-";
    case "application/zip":
      return bytes[0] === 80 && bytes[1] === 75 && [3, 5, 7].includes(bytes[2]);
    case "text/plain":
    case "text/vcard":
      try {
        const text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
        return !text.includes("\0") &&
          (mime !== "text/vcard" || text.startsWith("BEGIN:VCARD"));
      } catch {
        return false;
      }
    default:
      return false;
  }
}

// Bound container traversal; MIME labels alone cannot distinguish M4A from a
// video renamed .m4a. Parse ISO-BMFF handler boxes, never scan compressed data.
function mp4Tracks(bytes: Uint8Array) {
  const tracks = { audio: false, video: false };
  const data = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let budget = 10000;
  function boxes(start: number, end: number, depth: number): boolean {
    if (depth > 4) return false;
    for (let offset = start; offset < end;) {
      if (--budget < 0 || end - offset < 8) return false;
      let size = data.getUint32(offset);
      let header = 8;
      const type = ascii(bytes, offset + 4, 4);
      if (size === 1) {
        if (end - offset < 16) return false;
        const extended = data.getBigUint64(offset + 8);
        if (extended > BigInt(Number.MAX_SAFE_INTEGER)) return false;
        size = Number(extended);
        header = 16;
      } else if (size === 0) size = end - offset;
      if (size < header || offset + size > end) return false;
      if (["moov", "trak", "mdia"].includes(type)) {
        if (!boxes(offset + header, offset + size, depth + 1)) return false;
      } else if (type === "hdlr" && depth === 3 && size >= header + 12) {
        const handler = ascii(bytes, offset + header + 8, 4);
        if (handler === "soun") tracks.audio = true;
        if (handler === "vide") tracks.video = true;
      }
      offset += size;
    }
    return true;
  }
  if (!boxes(0, bytes.length, 0)) return { audio: false, video: false };
  return tracks;
}
