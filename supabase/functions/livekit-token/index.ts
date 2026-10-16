import { roomToken } from "../_shared/call_token.ts";
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
  const { client } = await authenticated(req);
  const input = await body(req);
  const id = uuid(input.call_id);
  const { data: call, error } = await client.rpc("authorize_call", {
    callid: id,
  });
  if (error || !call) throw new HttpError(403, "Call unavailable");
  const token = await roomToken(
    call.identity,
    call.room_name,
    call.video === true,
    required("LIVEKIT_API_KEY"),
    required("LIVEKIT_API_SECRET"),
  );
  return json({ url: required("LIVEKIT_URL"), token });
});
