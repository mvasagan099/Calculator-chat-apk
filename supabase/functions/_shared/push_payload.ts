export function pushPayload(
  job: { kind: string; resource_id: string; recipient_id?: string; expires_at?: string },
  token: string,
) {
  const call = job.kind === "call";
  const remaining = job.expires_at ? Math.floor((Date.parse(job.expires_at) - Date.now()) / 1000) : 86400;
  const ttl = Number.isFinite(remaining) ? Math.max(0, Math.min(86400, remaining)) : 0;
  return {
    message: {
      token,
      notification: call
        ? undefined
        : { title: "Calculator", body: job.kind === "message" ? "New update arrived" : "New activity" },
      data: {
        kind: job.kind,
        resource_id: job.resource_id,
        ...(job.recipient_id ? { recipient_id: job.recipient_id } : {}),
        ...(call
          ? {
            expires_at: job.expires_at ??
              new Date(Date.now() + 45000).toISOString(),
          }
          : {}),
      },
      android: {
        priority: call ? "HIGH" : "NORMAL",
        ttl: call ? "45s" : `${ttl}s`,
        notification: call ? undefined : {
          channel_id: "activity",
          icon: "ic_notification",
          visibility: "PRIVATE",
          tag: `${job.kind}:${job.resource_id}`,
        },
      },
    },
  };
}
