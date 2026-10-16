import { AccessToken, TrackSource } from "livekit-server-sdk";
// Only server-authorized values may enter here. Never accept room/identity from
// the request body. No room administration, recording or data-channel grants.
export async function roomToken(
  identity: string,
  room: string,
  video: boolean,
  key: string,
  secret: string,
): Promise<string> {
  const token = new AccessToken(key, secret, { identity, ttl: "90s" });
  token.addGrant({
    roomJoin: true,
    room,
    canPublish: true,
    canSubscribe: true,
    canPublishData: false,
    canUpdateOwnMetadata: false,
    canPublishSources: video
      ? [TrackSource.MICROPHONE, TrackSource.CAMERA, TrackSource.SCREEN_SHARE]
      : [TrackSource.MICROPHONE],
  });
  return await token.toJwt();
}
