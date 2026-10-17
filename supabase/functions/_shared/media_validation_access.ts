import { HttpError } from "./http.ts";

export interface MediaValidationAccess {
  bucket: string;
  path: string;
  userId: string;
  uploaderId: string | null | undefined;
  isConversationMember: (conversationId: string) => Promise<boolean>;
}

// Service-side, read-only preflight. It does not permit new client Storage
// operations and must run before ANY privileged Storage info/download response
// is used for media validation. The caller's JWT/device was verified earlier.
export async function checkMediaValidationAccess(input: MediaValidationAccess): Promise<void> {
  const { bucket, path, userId, uploaderId } = input;
  const parts = path.split("/");
  if (!["chat-media", "status-media", "avatars"].includes(bucket) ||
      path.length > 400 || parts.some((p) => !p || p === "." || p === "..") ||
      parts.length < (bucket === "chat-media" ? 3 : 2)) {
    throw new HttpError(400, "Invalid object");
  }
  const owner = bucket === "chat-media" ? parts[1] : parts[0];
  if (owner !== userId || uploaderId !== userId) {
    throw new HttpError(403, "Object owner mismatch");
  }
  if (bucket === "chat-media") {
    // A user-controlled path cannot substitute for a real membership query.
    if (!/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(parts[0]) ||
        !await input.isConversationMember(parts[0])) {
      throw new HttpError(403, "Conversation access unavailable");
    }
  }
}
