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
    let relevant = settings?.notifications === true;
    if (job.kind === "call") {
      const { data: call } = await admin.from("calls").select(
        "state,created_at",
      ).eq("id", job.resource_id).single();
      relevant = relevant && call?.state === "ringing" &&
        Date.now() - Date.parse(call.created_at) < 45000;
    } else if (job.kind === "message") {
      const { data: message } = await admin.from("messages").select(
        "conversation_id,sender_id,deleted_at",
      ).eq("id", job.resource_id).single();
      if (!message || message.deleted_at) relevant = false;
      else {
        const { data: member } = await admin.from("conversation_members")
          .select("muted").eq("conversation_id", message.conversation_id).eq(
            "user_id",
            job.recipient_id,
          ).maybeSingle();
        const { data: blocks } = await admin.from("user_blocks").select(
          "blocker_id",
        ).or(
          `and(blocker_id.eq.${job.recipient_id},blocked_id.eq.${message.sender_id}),and(blocker_id.eq.${message.sender_id},blocked_id.eq.${job.recipient_id})`,
        ).limit(1);
        relevant = relevant && !!member && !member.muted && !blocks?.length;
      }
    }
    const { data: tokens } = await admin.from("push_tokens").select("token").eq(
      "user_id",
      job.recipient_id,
    );
    let success = true;
    if (relevant) {
      for (const { token } of tokens ?? []) {
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
            body: JSON.stringify(pushPayload(job, token)),
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
