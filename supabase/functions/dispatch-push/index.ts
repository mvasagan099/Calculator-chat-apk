import { HttpError, json, serve, workerAuthorized } from "../_shared/http.ts";
import { dispatchPush } from "../_shared/push.ts";
serve(async (req) => {
  if (!workerAuthorized(req)) throw new HttpError(401, "Unauthorized");
  return json(await dispatchPush());
});
