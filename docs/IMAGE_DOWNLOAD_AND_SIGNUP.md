# Private image viewing and simplified account signup

Image and video downloads use POST \`download-chat-media\` Edge Function,
requiring a valid user JWT, approved device, server-confirmed conversation
membership and original visual-media expiry before a privileged private
Storage read. The previous authenticated Storage GET route returned HTTP 400
in Supabase's internal object.info lookup. No public buckets or bearer signed
visual URLs are introduced. Test on Android before calling the fix complete.

Signup now requests Display Name, unique lowercase Username, optional
mobile number, Password and Retype Password. Login still uses the existing
username/login ID; no existing accounts are renamed or deleted. Older APKs
sending \`user_id\` + display text under \`username\` remain compatible.
Phone numbers are privately stored, **unverified**, and not presently sufficient
to reset passwords. Existing one-time recovery codes remain required.

After CI: apply migration 016 once; deploy updated account-auth preserving
Cloudflare ingress enforcement, and deploy download-chat-media, with
verified JWT/device handling. Then perform negative authorization tests before
rebuilding the signed optimized APK. Do not uninstall or clear storage while
encrypted SQLite records remain unreadable.
