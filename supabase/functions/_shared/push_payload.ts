export function pushPayload(
  job: { kind: string; resource_id: string },
  token: string,
) {
  const call = job.kind === "call";
  return {
    message: {
      token,
      notification: { title: "Calculator", body: "New activity" },
      data: { kind: job.kind, resource_id: job.resource_id },
      android: {
        priority: call ? "HIGH" : "NORMAL",
        ttl: call ? "45s" : "86400s",
        notification: {
          channel_id: call ? "incoming_calls" : "activity",
          visibility: "PRIVATE",
          tag: call ? job.resource_id : undefined,
        },
      },
    },
  };
}
