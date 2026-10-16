import { jwtVerify } from "jose";
import { roomToken } from "./call_token.ts";
for (const video of [false, true]) {
  Deno.test(`call token uses bounded scoped ${video ? "video" : "voice"} grants`, async () => {
    const secret = "isolated-unit-test-only-not-a-provider-secret-0123456789";
    const identity = "test-user:test-join-epoch";
    const jwt = await roomToken(
      identity,
      "opaque-test-room",
      video,
      "test-key",
      secret,
    );
    const { payload } = await jwtVerify(jwt, new TextEncoder().encode(secret));
    const grant = payload.video as Record<string, unknown>;
    const sources = grant.canPublishSources as string[];
    if (
      payload.sub !== identity || grant.room !== "opaque-test-room" ||
      grant.roomJoin !== true || grant.canSubscribe !== true ||
      grant.canPublishData !== false || grant.canUpdateOwnMetadata !== false
    ) throw new Error("Incorrect call grant");
    if (
      (payload.exp ?? 0) - (payload.nbf ?? 0) > 90 ||
      (payload.exp ?? 0) - (payload.nbf ?? 0) < 1
    ) throw new Error("Token lifetime");
    if (
      sources.join(",") !==
        (video ? "microphone,camera,screen_share" : "microphone")
    ) throw new Error("Unexpected publish sources");
    for (
      const name of [
        "roomAdmin",
        "roomRecord",
        "roomCreate",
        "roomList",
        "recorder",
        "hidden",
      ]
    ) if (grant[name]) throw new Error("Elevated room privilege");
  });
}
