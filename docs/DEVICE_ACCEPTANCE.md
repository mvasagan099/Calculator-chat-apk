# Android acceptance procedure and current report

**Current result (2026-10-16): all 20 cases BLOCKED.** No APK, configured staging accounts/providers or attached Android devices are available. No case below has been executed on hardware. Unit/adapter/SQL tests are separate evidence. Use only two owner-authorized phones/profiles and disposable staging data, never personal chats/accounts.

## Prerequisites and evidence

Complete DEPLOYMENT.md and inspect the downloaded APK's signature, package `app.calculatorspace.calculator_messenger`, min API 29 and target API 36. Preview mode is insufficient for messaging/calls. Record source commit, APK SHA-256/certificate, build mode, phone models/API versions and network conditions. Keep serials, account credentials and content in a private test record; report only case ID/result/sanitized observations externally.

List devices and explicitly select each; do not run destructive default-device commands:

```sh
adb devices -l
sha256sum /path/to/app-debug.apk
apksigner verify --verbose --print-certs /path/to/app-debug.apk
adb -s PHONE_A_SERIAL install -r /path/to/app-debug.apk
adb -s PHONE_B_SERIAL install -r /path/to/app-debug.apk
adb -s PHONE_A_SERIAL shell am start -W -n app.calculatorspace.calculator_messenger/.MainActivity
adb -s PHONE_B_SERIAL shell am start -W -n app.calculatorspace.calculator_messenger/.MainActivity
```

A certificate mismatch must stop the test. Do not uninstall or clear data to bypass it on an existing owner installation. Use an authorized fresh disposable profile or the original signing identity. An AAB cannot be installed with `adb install`; first use trusted official bundletool as described in RELEASE.md. A successful install command alone does not verify startup/backend/media.

## Two-phone cases

Each case is currently **BLOCKED**. After prerequisites exist record PASS/FAIL/BLOCKED, device/API, build hash and sanitized evidence; leave unexecuted cases BLOCKED/NOT TESTED, never infer PASS.

| ID | Procedure | Expected result |
| --- | --- | --- |
| 01 | Verify certificate/hash and install on Phone A with explicit serial; start MainActivity. | Nonzero signed APK installs and starts; no crash. Cold start shows calculator/setup boundary, no private content. |
| 02 | Install the same hash on Phone B; launch/relaunch independently. | Same package/version/certificate; calculator gate holds. |
| 03 | Use Setup to register distinct staging accounts A/B; verify both email links; sign in separately. | Real Auth users/profiles exist; wrong password and unverified login fail safely. Never share account passwords in the report. |
| 04 | Create/confirm different local PINs on each phone; return to calculator. Enter correct PIN and `=`. | Only that authenticated device/account opens messenger; new setup itself does not silently unlock. |
| 05 | A discovers B and sends a unique non-sensitive test string; B replies. Repeat after navigating away/back. | Both receive through real Realtime; persisted history matches, stable IDs/no duplicates. |
| 06 | B receives while not viewing chat, then opens it; repeat reversed. Toggle receipt privacy. | Delivered/read indicators follow policy and synchronize on both devices. |
| 07 | Send a small image/video/PDF both directions; verify authorized preview/download. Attempt the same object with unrelated disposable account C. | Transfer/integrity/progress work; unauthorized object/message access denied. File limits/spoofed formats rejected. |
| 08 | Hold/record a short voice message; send/play/pause/change speed; deny and regrant mic permission in a separate trial. | Real recorded audio reaches peer; playback/cancellation and permission errors release capture. |
| 09 | Create group, invite B, accept, send text/media. Non-admin tries protected changes; remove/leave with authorized roles. | Membership/RLS permissions hold; group delivery persists. |
| 10 | A starts voice call; B answers; speak in both directions. Toggle mute, speaker/earpiece and paired Bluetooth; end from each side in separate trials. | Audible bidirectional media, valid state/history/duration, indicators/FGS disappear after local teardown. Record actual cleanup delay. |
| 11 | Repeat video call, front/rear camera, disable/enable camera, orientation change and camera denial/audio fallback. | Both real video/audio paths work; no duplicate tracks or lingering camera/mic capture after end. |
| 12 | Ring B while B is foreground, background, screen-locked and normally terminated (separate trials). Unlock via notification then explicitly answer/reject. | Generic notification/actions and server deadlines behave under OS policy; no automatic capture/private preview before Auth/PIN. Record each state independently. |
| 13 | Send messages/group/missed-call activity in foreground/background/terminated states; deny/regrant Android 13+ permission; refresh registration/reinstall only on disposable profile. | Appropriate generic notifications, intended recipient/token refresh and deep-link gate; permission denial handled. Send API success alone is insufficient. |
| 14 | During actual call switch Wi-Fi→mobile→Wi-Fi on A, then B; inspect quality and tracks. | SDK reconnect/recovery or clear terminal failure; no duplicate publications, private data in diagnostics or stale capture. |
| 15 | Disable network briefly during messaging and during a call; restore. Extend a separate media outage beyond grace period. | Stable-ID queue/retry drains without duplicates; session state/cleanup match documented reconnect/grace policy. |
| 16 | Background, manually relock, wait idle timeout, restart and normally terminate/reopen both apps; tap notification/deep link while locked. | Calculator/PIN and valid Auth/device gates always precede private content; recent-app/screenshot protection verified on that OEM. |
| 17 | Enter an incorrect numeric PIN five times and `=`; restart and retry during backoff; perform ordinary arithmetic too. | No unlock/disclosure, persisted throttle; calculator arithmetic remains normal. Correct PIN after permitted delay unlocks. |
| 18 | Inspect lock-screen, notification drawer, recents and screen capture while chats/call/media were previously open. | No sender/body/photo/chat history exposed while locked; mandatory Android call/capture notifications/indicators remain present. |
| 19 | Expire/revoke a disposable session/device and attempt cached navigation/new message/media/call token; sign out, recover via authorized Auth/PIN flow. | Initial uncertainty/denial fail closed; old session cannot request resources; no password-only device self-approval bypass. Existing offline copies/capabilities have documented limits. |
| 20 | Test ordinary process termination separately from `adb -s PHONE_B_SERIAL shell am force-stop app.calculatorspace.calculator_messenger`; send activity, then manually reopen B. | Force-stop delivery is not guaranteed and generally blocked until reopening. Reopen stays locked and history/queue/call metadata recover without duplicates/crash. Record actual OS behavior. |

## Additional required privacy/call cases

- On disposable accounts, set a short conversation expiry; test foreground/offline/reopen and deployed cleanup of message/media records. Open view-once on B, close/relock/background, try reopening/forward/export on both devices; normal paths must deny. Another camera/modified client cannot be prevented.
- Enable biometrics only after PIN confirmation; test failed/cancelled prompt, idle expiry during prompt and real backgrounding. Change/recover PIN with correct account authentication. Test email/password session recovery and account deletion only on run-owned disposable accounts, verifying cleanup without touching others.
- With two additional real users/phones C/D, test group voice then video, individual acceptance/rejection/leave, host/admin removal, invitations, participant pinning/speaker/mute, one peer reconnect and last participant departure. Record actual SFU media/CPU/battery; four-member SQL authorization is not four-party calling proof. No capacity guarantee is assumed.
- Make a waiting call from C while A/B are connected. Decline it or end-current/review; ensure two media sessions never remain joined for the same user. Multi-device ringing remains disabled.
- Screen sharing: explicitly accept/cancel Android's system prompt, verify the projection FGS/indicator, stop from UI/system, end/lock during pending consent and capture, rotate and reconnect. FLAG_SECURE can blank app capture; default background relocking stops sharing on app switch. Only test retaining unlock while backgrounded after the owner's explicit setting choice. Never disable secure-window protection to make a test pass.
- Repeat critical cases on minimum supported API 29, Android 13 notification permissions and Android 14+ capture/FGS restrictions. Test a minified signed build separately from debug. PiP/Telecom are not implemented and must not be marked PASS.

Do not attach raw notification token logs, authentication URLs, signed media links, personal screenshots, private heap dumps or account credentials to public issues/artifacts. A crash is FAIL even if a retry works; retain sanitized reproduction steps and rerun affected cases after a fix.
