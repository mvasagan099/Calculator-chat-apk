import { checkMediaValidationAccess } from "./media_validation_access.ts";
import { HttpError } from "./http.ts";

const user = "10000000-0000-0000-0000-000000000001";
const other = "10000000-0000-0000-0000-000000000002";
const conversation = "20000000-0000-0000-0000-000000000001";

async function expectDenied(input: Parameters<typeof checkMediaValidationAccess>[0], status: number) {
  let rejected = false;
  try {
    await checkMediaValidationAccess(input);
  } catch (error) {
    rejected = error instanceof HttpError && error.status === status;
  }
  if (!rejected) throw new Error("Expected secure validation rejection");
}

Deno.test("privileged inspection requires actual uploader and live conversation membership", async () => {
  let queried = 0;
  const owned = {
    bucket: "chat-media", path: `${conversation}/${user}/photo.jpg`,
    userId: user, uploaderId: user,
    isConversationMember: async (id: string) => {
      queried++;
      return id === conversation;
    },
  };
  await checkMediaValidationAccess(owned);
  if (queried !== 1) throw new Error("Membership not verified");
  await expectDenied({ ...owned, uploaderId: other }, 403);
  await expectDenied({ ...owned, path: `${conversation}/${other}/photo.jpg` }, 403);
  await expectDenied({ ...owned, isConversationMember: async () => false }, 403);
  await expectDenied({ ...owned, path: `not-a-uuid/${user}/photo.jpg` }, 403);
});

Deno.test("invalid/malformed paths never reach privileged file inspection", async () => {
  const basic = { bucket: "chat-media", path: `${conversation}/${user}/photo.jpg`,
    userId: user, uploaderId: user, isConversationMember: async () => true };
  for (const path of ["", "../a", `${conversation}/${user}/../a`,
    `${conversation}/${user}//name`, `${conversation}/${user}`]) {
    await expectDenied({ ...basic, path }, 400);
  }
  await expectDenied({ ...basic, bucket: "unknown" }, 400);
  await expectDenied({ ...basic, uploaderId: null }, 403);
});

Deno.test("avatar and status inspection needs uploader ownership, no unrelated chat membership", async () => {
  for (const bucket of ["avatars", "status-media"]) {
    await checkMediaValidationAccess({ bucket, path: `${user}/file.jpg`, userId: user,
      uploaderId: user, isConversationMember: async () => { throw Error("Unneeded chat lookup"); } });
    await expectDenied({ bucket, path: `${user}/file.jpg`, userId: user,
      uploaderId: other, isConversationMember: async () => true }, 403);
  }
});
