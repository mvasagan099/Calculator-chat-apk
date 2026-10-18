# Reliable Media Viewer and Downloads

This document details the implementation, architecture, and verification of the Reliable Media Viewer, Playback, and Download system in Calculator Messenger.

---

## 1. Summary of Enhancements

| Feature | Prior State | Enhanced State |
| :--- | :--- | :--- |
| **Full-Screen Image Viewing** | Minimal `InteractiveViewer` with default theme, no zoom reset, and vulnerable to byte zeroization if list recycled. | Dedicated `FullScreenImageViewer` with immersive dark UI, zoom controls (pinch/double-tap to 2.5×, reset), defensive memory buffer copying, secure zeroization on dispose, and `PrivateMediaGuard` expiry/lock protection. |
| **Video Playback** | Basic inline-only player; full-screen reused same controller causing Android texture conflicts and crashes on scroll. | Enhanced inline player with play/pause overlay, duration timestamps, scrubber, and dedicated `FullScreenVideoViewer` with auto-hiding controls, mute toggle, speed adjustment (1×/1.5×/2×), and replay. |
| **Audio Playback** | Text-only seconds counter with disabled button during load; no scrubbing; errors only triggered snackbar. | Interactive audio player with scrubber `Slider` for seeking, loading spinner, formatted duration (`mm:ss / mm:ss`), speed toggle (1×/1.5×/2×), and inline retry on playback failures. |
| **Document Opening** | Only generic download-and-share existed; no open action or in-app text preview. | Full document integration: dedicated file icons, open action (`open_in_new`), direct in-app reading for `.txt` files via `TextDocumentViewer`, external app launch via `url_launcher` (`https` queries configured for Android 11+), and fallback share. |
| **Download Progress** | Progress callback was unplumbed in visual media; progress was hidden or uninformative. | Plumbed `onProgress` through `MediaService.download`, `downloadAuthenticatedVisualBytes`, and `ExpiringAttachmentView`, showing linear progress indicators with exact percentage (`%`). |
| **Network Retry** | Single failure threw immediately, leaving dead "Media unavailable" text with no recovery. | Automated transient retry with exponential backoff in `MediaService.download` for socket/timeout/connection drops, plus user-facing **Retry** buttons on all media cards and viewers. |

---

## 2. Architecture & Security Invariants

### 2.1 Full-Screen Image Viewing (`full_screen_image_viewer.dart`)
* **Defensive Memory Management**: ListViews in Flutter recycle widgets when scrolled. The previous implementation passed `bytes!` directly; if the underlying chat tile was recycled or disposed, `forget()` zeroed the buffer in-place (`old.fillRange(0, old.length, 0)`), blanking out the full-screen view. `FullScreenImageViewer` makes a defensive buffer copy upon initialization (`Uint8List.fromList(widget.bytes)`), ensuring the full-screen viewer maintains an independent, intact buffer.
* **Zeroization on Route Exit**: When `FullScreenImageViewer` is popped, backgrounded, or locked, its own buffer is zeroed out, and memory images are evicted from `PaintingBinding.instance.imageCache`.
* **PrivateMediaGuard**: Wrapped around the screen scaffold; if the media deadline passes or the device locks, the viewer immediately transitions to `Media closed or expired`.

### 2.2 Full-Screen Video Playback (`full_screen_video_viewer.dart`)
* **Independent Surface Texture**: Sharing one `VideoPlayerController` across two concurrent `VideoPlayer` widgets causes Android `SurfaceTexture` collisions. `FullScreenVideoViewer` initializes an independent controller for the file and inherits `initialPosition` from the inline player.
* **Auto-hiding Controls**: Controls smoothly hide after 4 seconds of active playback, and re-appear on screen tap.

### 2.3 Audio Playback & Scrubber
* Integrates `just_audio` player state streams: `playerStateStream`, `positionStream`, and `durationStream`.
* Allows scrubbing to arbitrary positions via `Slider`.
* Displays current position alongside total audio duration (`0:15 / 1:30`).
* Provides 1×, 1.5×, and 2× playback speed cycling.

### 2.4 Document Opening & Fallbacks (`document_viewer.dart`, `attachment_view.dart`)
* **Plain Text (`.txt`)**: Authenticated download into memory, decoded as UTF-8, and rendered in `TextDocumentViewer` with monospace font and copy/share actions.
* **Binary Documents (`.pdf`, `.zip`, `.vcf`)**:
  1. Primary path: Calls `MediaService.signedUrl(a)` to obtain a short-lived bearer URL and launches with `launchUrl(uri, mode: LaunchMode.externalApplication)`.
  2. Fallback path: If external browser/viewer launch fails or device lacks a direct handler, downloads the file with progress, saves to `PrivateMediaFiles()`, and prompts the Android system share sheet (`SharePlus`).

### 2.5 Android 11+ Package Visibility (`AndroidManifest.xml`)
* Added `<queries>` intent declarations for `https` and `http` schemes to `android/app/src/main/AndroidManifest.xml`, ensuring `url_launcher` can resolve default browsers and external PDF/document viewers on API 30 and above.

---

## 3. Test & Verification Matrix

* `test/reliable_media_viewer_test.dart`:
  * `FullScreenImageViewer`: Interactive zoom, double-tap zoom, reset zoom action, and memory clearing upon expiry.
  * `TextDocumentViewer`: Selectable text rendering, document title, and sharing.
  * `ExpiringAttachmentView`: Network failure recovery with Retry button and progress indicator.
  * `AttachmentView`: Document tile icon/size, open action, audio player slider, duration display, and speed cycling.
* `test/media_download_test.dart`:
  * Validates visual media download Edge route handling.
  * Validates size bounds, stream termination, and immediate failure for non-transient errors (invalid sizes, expired deadlines).
* `scripts/tests/`:
  * Launcher icon manifest checks pass.
  * Client config validation tests pass (18 tests).
  * PIN KDF and launcher alias verification pass.
