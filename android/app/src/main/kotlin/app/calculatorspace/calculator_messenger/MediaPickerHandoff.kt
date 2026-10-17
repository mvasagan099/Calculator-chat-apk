package app.calculatorspace.calculator_messenger

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** One in-memory activity-result lease; never persisted or restored. Broadcasts
 * can only invalidate it, never approve a result or open private Flutter UI. */
class MediaPickerHandoff(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "calculator_messenger/media_picker")
    private val handler = Handler(Looper.getMainLooper())
    private var token: String? = null
    private var kind: String? = null
    private var request: Int? = null
    private var returned = false
    private var left = false
    private var resumed = false
    private var finish: MethodChannel.Result? = null
    private val deadline = Runnable { invalidate() }
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            // Home, Recents, screen lock, notification shade/system switching.
            // Fail closed for any system-dialog-close reason, including OEMs.
            invalidate()
        }
    }

    init {
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_CLOSE_SYSTEM_DIALOGS)
            addAction(Intent.ACTION_SCREEN_OFF)
        }
        // System UI may run outside the system UID. Spoofed broadcasts can only
        // lock, so exporting this dynamic invalidation-only receiver is safe.
        if (Build.VERSION.SDK_INT >= 33) activity.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
        else activity.registerReceiver(receiver, filter)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "arm" -> {
                    val id = call.argument<String>("token")
                    val source = call.argument<String>("kind")
                    if (token != null || id.isNullOrEmpty() || source !in listOf("image", "video", "camera", "document") || !resumed || !activity.hasWindowFocus()) {
                        result.success(false)
                    } else {
                        token = id; kind = source; request = null; returned = false; left = false
                        handler.postDelayed(deadline, 120_000)
                        result.success(true)
                    }
                }
                "finish" -> {
                    if (call.argument<String>("token") != token || token == null || (!returned && left) || finish != null) {
                        result.success(false)
                    } else if (resumed) {
                        val valid = returned || !left
                        clear(); result.success(valid)
                    } else finish = result
                }
                "cancel" -> {
                    if (call.argument<String>("token") == token) clear()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    fun launching(intent: Intent, requestCode: Int) {
        if (token == null) return
        val target = if (intent.action == Intent.ACTION_CHOOSER) {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT) ?: intent
        } else intent
        val media = target.type?.startsWith("image/") == true || target.type?.startsWith("video/") == true
        val photoAction = target.action in listOf("android.provider.action.PICK_IMAGES", "androidx.activity.result.contract.action.PICK_IMAGES", "com.google.android.gms.provider.action.PICK_IMAGES")
        val allowed = when (kind) {
            "camera" -> target.action == "android.media.action.IMAGE_CAPTURE"
            "document" -> target.action in listOf(Intent.ACTION_GET_CONTENT, Intent.ACTION_OPEN_DOCUMENT)
            else -> (photoAction || target.action in listOf(Intent.ACTION_GET_CONTENT, Intent.ACTION_OPEN_DOCUMENT, Intent.ACTION_PICK)) && media
        }
        if (!allowed || request != null || requestCode < 0) { invalidate(); return }
        request = requestCode
        // This launch is explicit app work, not Home/Recents. Home while the
        // external picker is active is handled by the invalidation receiver.
        intent.addFlags(Intent.FLAG_ACTIVITY_NO_USER_ACTION)
    }

    fun result(requestCode: Int) {
        if (token != null && request == requestCode) returned = true
    }
    fun paused() { resumed = false; if (token != null && request != null) left = true }
    fun stopped() { if (token != null && request == null) invalidate() }
    fun resumed() {
        resumed = true
        if (token == null) return
        if (left && !returned) { invalidate(); return }
        finish?.let { pending ->
            finish = null
            clear()
            pending.success(true)
        }
    }
    fun invalidate() {
        val id = token ?: return
        clear()
        channel.invokeMethod("invalidated", id)
    }
    private fun clear() {
        handler.removeCallbacks(deadline)
        token = null; kind = null; request = null; returned = false; left = false
        finish?.success(false); finish = null
    }
    fun close() {
        invalidate()
        activity.unregisterReceiver(receiver)
        channel.setMethodCallHandler(null)
    }
}
