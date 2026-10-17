# Media picker lifecycle handoff — prepared, not released

The original Updates/gallery issue was caused by treating the picker activity's
inactive/hidden/paused transitions as ordinary application backgrounding. Relocking
then redirected the router and replaced the private widget subtree with Calculator,
discarding its selection/upload state. The same call pattern existed in chat and
profile/group image selection.

## Scope and behavior

`LockController.pickMedia` is available only from an already unlocked, approved,
foreground session. It never calls `_open`, verifies no PIN itself, and cannot
restore an already locked session. The existing background-lock preference is
never disabled or changed. One handoff at a time is permitted, bounded by two
minutes **and** the existing inactivity timer, whichever expires first.

Before launching, Flutter paints a neutral privacy cover and excludes the private
navigator from painting, focus and semantics. Private route widgets stay mounted
offstage, preserving Updates/posting and chat state. `FLAG_SECURE` remains enabled.
Calculator/PIN/hidden-biometric behavior is unchanged outside this operation.

Android's `MediaPickerHandoff` arms one in-memory token. `MainActivity` intercepts
the next `startActivityForResult` and accepts only an expected gallery/photo picker,
camera capture or document selection intent. Unknown/second launches invalidate
the handoff. The launch uses `FLAG_ACTIVITY_NO_USER_ACTION` so it is not mistaken
for explicit user navigation away. Both a selected result and Android cancellation
must match that exact request code. A permission denial that never launched an
external activity can finish without an activity result if the host never stopped.

Return requires native activity-result proof and host resume, then the same Auth
UUID, session UUID, owner-bound PIN, unlock epoch and device authorization. Device
authorization is refreshed before removing the privacy cover or using a file. A
cancelled picker returns without uploading/posting. Exceptions, absent/empty/large
files and rejected media stop before posting. Updates and chat retain existing
Supabase storage permissions and `validate-media`; no server gate was removed.

The handoff is used for Updates images/videos, chat gallery/camera/video/document
attachments, group pictures and profile avatars. User ID/no-email account changes
and hidden biometric changes prepared earlier remain in the combined patch.

## Invalidation and security boundary

- Manual relock, timeout, session/device revocation and account/session changes
  invalidate the original epoch. A stale callback cannot open private UI, post as
  another account, or relock a newer successfully unlocked session.
- Android user-leave callbacks, system-dialog-close broadcasts (Home/Recents/system
  switching), screen-off, unexpected intents/returns, activity destruction and
  detachment invalidate the native lease. Broadcasts can only invalidate; none can
  approve a result or unlock. An exported dynamic receiver receives System UI
  signals and contains no data-return or authorization operation.
- Outside an armed handoff, inactive/paused/hidden lifecycle handling retains the
  original global policy. Inside it, the whole private navigator remains masked
  until native proof and current authorization succeed. Missing native bridge,
  unsupported intent, wrong result token/code and return timeout fail closed.
- Neither native nor Dart leases are persisted. Cold startup starts locked; this
  patch does not auto-post `retrieveLostData` after process death.
- Media operations capture owner/session/epoch and widget lifetime before opening
  the picker. Checks after file work, upload and validation prevent stale callbacks
  from invoking the subsequent post/send/profile update. An HTTP request already
  accepted by the server cannot be recalled; abandoned uploaded objects may remain
  subject to existing server cleanup. No production cleanup policy was changed.

**Android acceptance is pending.** Lifecycle alone does not identify Home while an
external activity owns the screen. This implementation additionally relies on
Android delivering native user-leave/system-dialog/screen-off signals, plus its
activity-result protocol. `ACTION_CLOSE_SYSTEM_DIALOGS` is deprecated; OEM and
gesture-navigation delivery must be tested, especially Home/Recents while the
picker itself is foreground. Unit doubles cannot prove those platform signals.
Do not claim the Home/Recents requirement passed or approve a release on a device
where those signals are missing. Unsupported picker implementations fail closed
when detected. No privileged usage-access permission or task monitoring was added.

## Reproducible checks and current results

```sh
python3 scripts/test-media-picker-native.py
python3 -m unittest discover -s scripts/tests -p '*_test.py'
flutter analyze
flutter test
```

The native test requires JDK and a trusted installed Kotlin compiler (`KOTLINC`
may point to one; macOS Android Studio's bundled compiler is detected). It compiles
and executes the **actual handoff implementation** with Android/channel doubles.
Fourteen cases passed locally: image/video/camera/document, system leave/screen
off, wrong/late result, manual cancellation, unexpected launch, repeated arm,
deadline, return-before-resume, unexpected stop and stale tokens. This is not a
real Android framework/instrumentation run.

The helper also compiles against installed Android SDK 36 with temporary Flutter
channel API stubs. Full `MainActivity`/Flutter Gradle compilation remains pending.
The 46 existing tooling tests and all 19 Deno Edge tests passed. Actionlint with
ShellCheck and whitespace checks passed. No dependency lockfiles, release signing,
APK size checks, workflow security gates or backend deployment settings changed
for this fix; the earlier release-workflow change remains preserved separately.

Added Flutter handoff tests cover all four picker kinds, cancellation, native
rejection, regular backgrounding, Home/Recents invalidation, manual relock,
session/device/account changes, timeout, detachment, concurrent attempts and stale
callbacks. New **actual StatusScreen** widget tests use a controlled file selector
and mocked Supabase HTTP to check image/video upload + validation + post, cancel,
missing file, Home, manual lock, device/session loss and repeated launch. They also
assert private content is offstage while selecting and the same widget state
survives a normal return. These tests are added but **unrun** because Flutter is
unavailable. Deno/provider mocks do not validate real Supabase or Android behavior.

## Required Android acceptance before release

On an authorized Android phone, test with existing inactivity/background settings:

1. PIN + required biometrics → Updates → New image → choose → same Updates and one
   validated post. Repeat for video and cancellation (zero post).
2. Chat gallery/camera (including first permission grant/denial), video/document,
   group picture and avatar: preserve route; upload only for the original session.
3. While each picker is foreground: Home, gesture/button Recents, switch apps,
   screen off, notification navigation, manual lock and inactivity timeout. Return
   and select/cancel: remain locked; no stale file posts or private content flashes.
4. Revoke device/session or switch account while selecting; kill the process and
   restart; return without a valid activity result; deny permission; remove the
   selected file; repeat taps. No callback may reopen private content.
5. Verify PIN + biometric cancellation/backgrounding tests still pass, and inspect
   app/Recents screenshots for private content under the privacy cover.

No phone was used, APK built, code pushed, signing identity changed, or backend
deployed for this implementation.

Platform references: [Activity lifecycle](https://developer.android.com/reference/android/app/Activity),
[Intent flags](https://developer.android.com/reference/android/content/Intent),
[image_picker lifecycle guidance](https://github.com/flutter/packages/blob/main/packages/image_picker/image_picker/README.md).
