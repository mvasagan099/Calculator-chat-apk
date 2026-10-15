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
    case "audio/mp4":
      return ascii(bytes, 4, 4) === "ftyp";
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
