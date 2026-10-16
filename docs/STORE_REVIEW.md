# Store disclosure and policy review gate

**Not submitted/published. Current live-policy verification is BLOCKED.** On 2026-10-16 this environment could not fetch official Google Play policy or Android foreground-service pages (proxy CONNECT 403). The links/checklist below identify required owner review; they are not a claim of current policy compliance or approval.

Official references:

- [Deceptive behavior / hidden functionality](https://support.google.com/googleplay/android-developer/answer/9888077?hl=en)
- [User data, privacy policy and prominent disclosure](https://support.google.com/googleplay/android-developer/answer/10144311?hl=en)
- [Data safety form](https://support.google.com/googleplay/android-developer/answer/10787469?hl=en)
- [Target API requirements](https://support.google.com/googleplay/android-developer/answer/11926878?hl=en)
- [Foreground service types and requirements](https://developer.android.com/develop/background-work/services/fgs/service-types)
- [Full-screen intent restrictions](https://developer.android.com/about/versions/14/behavior-changes-14#secure-fsi-notifications)

## Required transparent description

The store listing, screenshots, privacy policy, onboarding and reviewer notes must clearly disclose **both calculator and messaging/calling functionality**, the PIN unlock, provider/account requirements, permissions and actual encryption limits. The launcher may retain its requested calculator style for owner privacy, but must not be used to hide undocumented functionality from users/reviewers. Do not ship review-only behavior, remote hidden activation, false E2EE claims, WhatsApp trademarks/assets or claims of invisibility in Android settings.

A future listing draft, only after the associated features pass acceptance:

> Calculator Messenger combines a working calculator with an account-based private messaging and internet-calling space protected by a separate device PIN. Enter the configured PIN and press equals to open the messenger. The app uses Supabase for authentication/messages/media, LiveKit for calling and Firebase for optional notifications. Notifications are generic by default. Calculator locking protects ordinary device access; messages and media are not currently end-to-end encrypted, and required Android permissions/indicators remain visible.

Do not publish this draft as evidence that calling/notifications work: those integrations are still unverified here. Supply reviewer access and unlock/setup instructions privately through the Play Console, using run-owned review accounts; never place real passwords/PINs in Git, public metadata or this chat. Device approval/recovery must have an approved, tested reviewer-access plan without weakening global RLS or adding a hidden bypass.

## Data and permissions to assess against the actual release

Inventory account/email/public IDs, profiles, messages/receipts/reactions, photos/video/audio/documents, explicitly shared contact cards/location, group/status/call metadata, app device IDs, Auth sessions, push registrations and network/service operational metadata. Server-readable content must be disclosed accurately. Review Supabase/LiveKit/Firebase SDK collection and retention, processors/regions, secure transport, account deletion and status/message/media expiry, including backups/capability limits. No device address book is automatically uploaded; no crash-reporting provider has been configured. Do not infer a completed Data Safety form from these source observations.

Declared app permissions include Internet/network, foreground microphone/camera, Bluetooth routing, notification permission, one-time foreground location and MediaProjection FGS. Review the actual merged manifest/dependencies after a successful build; source manifest alone cannot establish the final permission inventory. Request optional permissions in context with clear denial behavior. No SMS/call-log/contact-sync/system-dialer/Telecom/full-screen-intent entitlement is being assumed. Mandatory capture/FGS disclosures must remain visible.

The source declares package `app.calculatorspace.calculator_messenger`, calculator label/original adaptive icon, min API 29, target API 36 and version `1.0.0+1`. Confirm current Play target/API and signing/key-lifetime requirements at submission time, choose a monotonically increasing version code relative to the real listing, and complete privacy/account-deletion/support URLs with an owner-controlled domain. No invented policy URL, legal assurance, version history or Play signing identity is supplied.

Release remains blocked until current policies, completed Data Safety/privacy disclosures, reviewer access, all mandatory acceptance gates and an actual signed artifact are reviewed. CI upload is internal artifact preparation; no workflow here publishes to Google Play or GitHub Releases.
