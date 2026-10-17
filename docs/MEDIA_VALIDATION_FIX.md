# Image/video upload validation fix

When Storage's restrictive visual-read policy is enforced, an uploaded picture
is not yet attached to a chat message. The old `validate-media` function used
the *user* Storage download, which could fail with 403 in this pre-attachment
state. The project showed three JPEG objects present with no media validation
records while a text file was successfully validated.

The updated Edge validation function first requires a valid Supabase JWT and
approved device (existing `authenticated` gate), verifies the exact Storage
uploader ID from privileged object metadata, and checks the caller's **current**
conversation membership using a user-scoped database request. Only after all
checks pass does the Edge function download bytes internally using its existing
service role to validate file signatures, MIME, size, and 48-hour visual expiry.
The normal authenticated media *viewing* policies are unchanged; no bytes, media
URLs, or service-role credentials are returned to the client.

**Deployment required:** Deploy the updated `validate-media` Edge Function
from this branch after tests pass. No bucket-public setting, RLS disablement,
or SQL migration is required. Do not attempt to revalidate orphaned older files
by hand or rerun migration history. Existing unvalidated objects are not
automatically retried; test with a **new** JPEG and an MP4 in a currently
approved conversation. Test blocked/non-member requests and account/device
revocation; inspect 403 and 200 responses. Confirm the Flutter picker remains
unlocked on return, separately: that is native handoff behavior, not fixed by
this server-side upload patch.

Current tests are isolated logic tests, not live Supabase Storage or Android
device tests. A successful GitHub CI run does not imply the function is deployed.
