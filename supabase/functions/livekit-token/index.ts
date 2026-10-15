import { AccessToken } from "livekit-server-sdk";
import {
  authenticated,
  body,
  HttpError,
  json,
  required,
  serve,
  uuid,
} from "../_shared/http.ts";
serve(async (req) => {
  const { user, client } = await authenticated(req);
  const input = await body(req);
  const id = uuid(input.call_id);
  const { data: call, error } = await client.rpc("authorize_call", {
    callid: id,
  });
  if (error || !call) throw new HttpError(403, "Call unavailable");
  const token = new AccessToken(
    required("LIVEKIT_API_KEY"),
    required("LIVEKIT_API_SECRET"),
    { identity: user.id, ttl: "5m" },
  );
  token.addGrant({
    roomJoin: true,
    room: call.room_name,
    canPublish: true,
    canSubscribe: true,
    canPublishData: false,
  });
  return json({ url: required("LIVEKIT_URL"), token: await token.toJwt() });
});
