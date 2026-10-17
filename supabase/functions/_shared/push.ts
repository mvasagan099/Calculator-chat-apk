import { importPKCS8, SignJWT } from "jose";
import { adminClient, required } from "./http.ts";
import { pushPayload } from "./push_payload.ts";
export async function dispatchPush() {
  const admin = adminClient();
  const { data: jobs, error } = await admin.rpc("claim_notification_jobs");
  if (error) throw error;
  if (!jobs?.length) return { processed: 0 };
  const account = JSON.parse(required("FIREBASE_SERVICE_ACCOUNT"));
  const key = await importPKCS8(account.private_key, "RS256");
  const assertion = await new SignJWT({
    scope: "https://www.googleapis.com/auth/firebase.messaging",
  }).setProtectedHeader({ alg: "RS256" }).setIssuer(account.client_email)
    .setAudience("https://oauth2.googleapis.com/token").setIssuedAt()
    .setExpirationTime("1h").sign(key);
  const oauth = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });
  if (!oauth.ok) throw new Error("FCM authorization failed");
  const { access_token } = await oauth.json();
  let processed = 0;
  for (const job of jobs) {
    const { data: settings } = await admin.from("user_settings").select(
      "notifications",
    ).eq("user_id", job.recipient_id).single();
    let invitationExpiry: string | undefined;
    let relevant = settings?.notifications === true;
    if (job.kind === "call") {
      const { data: call } = await admin.from("calls").select(
        "state,created_at",
      ).eq("id", job.resource_id).single();
      const { data: invitation } = await admin.from("call_participants")
        .select("state,invitation_expires_at").eq("call_id", job.resource_id)
        .eq("user_id", job.recipient_id).maybeSingle();
      invitationExpiry = invitation?.invitation_expires_at;
      relevant = relevant &&
        ["ringing", "accepted"].includes(call?.state ?? "") &&
        invitation?.state === "invited" &&
        Date.parse(invitation.invitation_expires_at) > Date.now();
    } else if (job.kind === "message") {
      const { data: target, error: targetError } = await admin.rpc("message_push_target", {
        mid: job.resource_id, recipient: job.recipient_id,
      });
      if (targetError) throw targetError; // Fail closed; do not silently drop jobs during schema rollout.
      relevant = relevant && !!target;
      invitationExpiry = target?.expires_at ?? undefined;
    }
    const { data: tokens, error: tokenError } = await admin.rpc(
      job.kind === "call" ? "call_notification_tokens" : "notification_tokens",
      job.kind === "call"
        ? { callid: job.resource_id, recipient: job.recipient_id }
        : { recipient: job.recipient_id },
    );
    if (tokenError) throw tokenError;
    let success = true;
    if (relevant) {
      for (const { token } of tokens ?? []) {
        if (invitationExpiry && !(Date.parse(invitationExpiry) > Date.now())) break;
        const response = await fetch(
          `https://fcm.googleapis.com/v1/projects/${
            encodeURIComponent(account.project_id)
          }/messages:send`,
          {
            method: "POST",
            headers: {
              Authorization: `Bearer ${access_token}`,
              "Content-Type": "application/json",
            },
            body: JSON.stringify(
              pushPayload({ ...job, expires_at: invitationExpiry }, token),
            ),
          },
        );
        if (response.status === 404) {
          await admin.from("push_tokens").delete().eq(
            "user_id",
            job.recipient_id,
          ).eq("token", token);
        } else if (!response.ok) success = false;
      }
    }
    if (success) {
      await admin.from("notification_jobs").update({
        sent_at: new Date().toISOString(),
        lease_until: null,
      }).eq("id", job.id);
      processed++;
    }
  }
  return { processed };
}
