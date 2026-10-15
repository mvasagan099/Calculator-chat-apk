import { createClient } from "@supabase/supabase-js";
export const json = (value: unknown, status = 200) =>
  new Response(JSON.stringify(value), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    },
  });
export function required(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`Server configuration missing: ${name}`);
  return value;
}
export function adminClient() {
  return createClient(
    required("SUPABASE_URL"),
    required("SUPABASE_SERVICE_ROLE_KEY"),
    { auth: { persistSession: false, autoRefreshToken: false } },
  );
}
export async function authenticated(req: Request) {
  const authorization = req.headers.get("authorization");
  if (!authorization?.startsWith("Bearer ")) {
    throw new HttpError(401, "Authentication required");
  }
  const token = authorization.slice(7);
  const userClient = createClient(
    required("SUPABASE_URL"),
    required("SUPABASE_ANON_KEY"),
    {
      global: { headers: { Authorization: authorization } },
      auth: { persistSession: false, autoRefreshToken: false },
    },
  );
  const { data, error } = await userClient.auth.getUser(token);
  if (error || !data.user) throw new HttpError(401, "Session invalid");
  const { data: access, error: accessError } = await userClient.rpc(
    "device_access_status",
  );
  if (accessError || access?.authorized !== true) {
    throw new HttpError(403, "Approved device required");
  }
  return { user: data.user, client: userClient, admin: adminClient() };
}
export class HttpError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}
export async function body(req: Request): Promise<Record<string, unknown>> {
  if (req.method !== "POST") throw new HttpError(405, "POST required");
  const input = await req.text();
  if (input.length > 16384) throw new HttpError(413, "Request too large");
  try {
    const parsed = JSON.parse(input);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      throw new Error();
    }
    return parsed;
  } catch {
    throw new HttpError(400, "Invalid JSON");
  }
}
export function uuid(value: unknown): string {
  if (
    typeof value !== "string" ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
      value,
    )
  ) throw new HttpError(400, "Invalid ID");
  return value;
}
export function serve(handler: (req: Request) => Promise<Response>) {
  Deno.serve(async (req) => {
    try {
      return await handler(req);
    } catch (e) {
      return e instanceof HttpError
        ? json({ error: e.message }, e.status)
        : json({ error: "Operation failed" }, 500);
    }
  });
}
export function workerAuthorized(req: Request): boolean {
  const expected = required("MAINTENANCE_SECRET");
  const actual = req.headers.get("x-worker-secret") ?? "";
  if (expected.length < 32 || actual.length !== expected.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) {
    diff |= actual.charCodeAt(i) ^ expected.charCodeAt(i);
  }
  return diff === 0;
}
