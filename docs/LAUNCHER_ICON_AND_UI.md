# Calculator icon personalization and smooth private UI

Chat Settings → Personalization → **Calculator app icon** offers Classic, Midnight, Graphite and Sunrise. Changing a choice toggles one of four prepackaged Android `activity-alias` launcher entries, so no launcher icon artwork is downloaded at runtime. Only the launcher alias is switched; `MainActivity`, PIN verification, secure storage, deep links, notifications, and app signing identity remain unchanged. Default Classic uses the original shipped icon. Launcher caches can take a few seconds to refresh.

Modern private UI uses Material 3 card/button/divider and tile treatments and lightweight 190ms private-tab slide/fade transitions. Calculator-to-private lock/unlock still uses the existing privacy gate, not a shared transition; this avoids revealing locked content. No new packages, Firebase/Supabase requests, or asset downloads.

Validate on Android 10+/API 29+: install/update signed APK, open Settings, select all four icons and confirm exactly one launcher appears; reboot and verify selection persists; test return-to-calculator, deep links, notifications and PIN relock. Do not uninstall a device with unreadable encrypted SQLite cache. Test under reduced-motion settings and low-end hardware before release.
