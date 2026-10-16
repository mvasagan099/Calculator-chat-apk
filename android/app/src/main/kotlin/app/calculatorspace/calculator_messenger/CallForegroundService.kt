package app.calculatorspace.calculator_messenger

import android.app.*
import android.content.*
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

class CallForegroundService : Service() {
    companion object {
        var onEnd: ((String) -> Unit)? = null
        var ready: Pair<String, (Boolean) -> Unit>? = null
        var session: String? = null
        var callId: String? = null
        fun stop(context: Context, id: String) {
            if (session != id) return
            if (ready?.first == id) { ready?.second?.invoke(false); ready = null }
            ProjectionForegroundService.stop(context,id)
            session = null
            callId = null
            context.stopService(Intent(context, CallForegroundService::class.java))
        }
    }
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val id = intent?.getStringExtra("id")
        if (id == null || session != id) {
            stopSelf(startId)
            return START_NOT_STICKY
        }
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel("active_call", "Active call", NotificationManager.IMPORTANCE_LOW).apply {
            lockscreenVisibility = Notification.VISIBILITY_PRIVATE
        })
        val open = PendingIntent.getActivity(this, 20, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        // Unique data keeps an old notification action tied to its own session.
        val endIntent = Intent(this, EndCallReceiver::class.java).setData(android.net.Uri.parse("calculator-call:$id")).putExtra("id", id)
        val end = PendingIntent.getBroadcast(this, 21, endIntent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val notification = Notification.Builder(this, "active_call")
            .setSmallIcon(R.drawable.ic_notification).setContentTitle("Calculator")
            .setContentText("Call in progress").setCategory(Notification.CATEGORY_CALL)
            .setVisibility(Notification.VISIBILITY_PRIVATE).setOngoing(true).setContentIntent(open)
            .addAction(Notification.Action.Builder(null, "End call", end).build()).build()
        try {
        // Microphone/camera foreground types were introduced in Android 11.
        if (Build.VERSION.SDK_INT >= 30) {
            var type = ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            if (intent?.getBooleanExtra("video", false) == true) type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
            startForeground(31, notification, type)
        } else startForeground(31, notification)
        if (ready?.first == id) { ready?.second?.invoke(true); ready = null }
        } catch (e: RuntimeException) {
            if (ready?.first == id) { ready?.second?.invoke(false); ready = null }
            stop(this,id)
        }
        return START_NOT_STICKY
    }
}
class EndCallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra("id") ?: return
        if (CallForegroundService.session != id) return
        CallForegroundService.callId?.let { CallForegroundService.onEnd?.invoke(it) }
        CallForegroundService.stop(context, id)
    }
}
