import { createClient } from "@supabase/supabase-js";
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
  const { user, client, admin } = await authenticated(req);
  const input = await body(req);
  const action = String(input.action);
  if (
    !["enable", "approve", "revoke", "revoke_others", "reauthenticate"]
      .includes(action)
  ) {
    throw new HttpError(400, "Invalid operation");
  }
  if (
    typeof input.password !== "string" || input.password.length < 1 ||
    input.password.length > 256 || !user.email
  ) throw new HttpError(400, "Password reauthentication required");
  const { error: rateError } = await client.rpc("begin_device_security");
  if (rateError) throw new HttpError(429, "Security operation unavailable");
  const { data: access, error: accessError } = await client.rpc(
    "device_access_status",
  );
  if (accessError || !access?.session_id || !access.authorized) {
    throw new HttpError(403, "Approved device required");
  }
  // Isolated password proof: never replace the caller's authorized session or
  // persist either password or the temporary verification session.
  const proofClient = createClient(
    required("SUPABASE_URL"),
    required("SUPABASE_ANON_KEY"),
    {
      auth: { persistSession: false, autoRefreshToken: false },
    },
  );
  const { data: proof, error: proofError } = await proofClient.auth
    .signInWithPassword({ email: user.email, password: input.password });
  if (proofError || proof.user?.id !== user.id || !proof.session) {
    throw new HttpError(401, "Reauthentication failed");
  }
  try {
    if (action === "reauthenticate") return json({ reauthenticated: true });
    const { error } = await admin.rpc("manage_account_device", {
      actor: user.id,
      actor_session: access.session_id,
      operation: action,
      device: action === "enable" ? uuid(input.device_id) : null,
      device_name: action === "enable"
        ? String(input.name ?? "Android device").slice(0, 80)
        : null,
      target: action === "approve" || action === "revoke"
        ? uuid(input.target)
        : null,
      code: action === "approve" ? String(input.code ?? "") : null,
    });
    if (error) throw new HttpError(403, "Device operation unavailable");
    return json({ updated: true });
  } finally {
    await admin.auth.admin.signOut(proof.session.access_token, "local");
  }
});
