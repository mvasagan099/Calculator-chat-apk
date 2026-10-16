import { RoomServiceClient } from "livekit-server-sdk";
import { required } from "./http.ts";
export async function closeRoom(room: string): Promise<void> {
  const url = required("LIVEKIT_URL").replace(/^wss:/, "https:");
  if (!url.startsWith("https://")) {
    throw new Error("HTTPS LiveKit endpoint required");
  }
  const service = new RoomServiceClient(
    url,
    required("LIVEKIT_API_KEY"),
    required("LIVEKIT_API_SECRET"),
  );
  try {
    await service.deleteRoom(room);
  } catch (e) {
    if (
      e && typeof e === "object" &&
      (("code" in e && e.code === "not_found") ||
        ("status" in e && e.status === 404))
    ) return;
    throw e;
  }
}

export async function removeParticipant(
  room: string,
  identity: string,
): Promise<void> {
  const url = required("LIVEKIT_URL").replace(/^wss:/, "https:");
  if (!url.startsWith("https://")) throw new Error("HTTPS endpoint required");
  const service = new RoomServiceClient(
    url,
    required("LIVEKIT_API_KEY"),
    required("LIVEKIT_API_SECRET"),
  );
  try {
    await service.removeParticipant(room, identity);
  } catch (e) {
    if (
      e && typeof e === "object" &&
      (("code" in e && e.code === "not_found") ||
        ("status" in e && e.status === 404))
    ) return;
    throw e;
  }
}
