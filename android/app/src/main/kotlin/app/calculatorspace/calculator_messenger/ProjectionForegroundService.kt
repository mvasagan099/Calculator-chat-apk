package app.calculatorspace.calculator_messenger

import android.app.*
import android.content.*
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/** Started only after WebRTC's system MediaProjection consent succeeds. */
class ProjectionForegroundService : Service() {
    companion object {
        var session: String? = null
        var ready: ((Boolean) -> Unit)? = null
        fun stop(context: Context, id: String) {
            if (session != id) return
            session = null
            ready?.invoke(false)
            ready = null
            context.stopService(Intent(context, ProjectionForegroundService::class.java))
        }
    }
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val id = intent?.getStringExtra("id")
        if (id == null || session != id) {
            stopSelf(startId)
            return START_NOT_STICKY
        }
        if (CallForegroundService.session != id) {
            ready?.invoke(false); ready = null
            stopSelf(startId)
            return START_NOT_STICKY
        }
        try {
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(NotificationChannel("screen_share", "Screen sharing", NotificationManager.IMPORTANCE_LOW))
            val open = PendingIntent.getActivity(this, 30, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            val notification = Notification.Builder(this,"screen_share").setSmallIcon(R.drawable.ic_notification)
                .setContentTitle("Calculator").setContentText("Screen sharing is active")
                .setVisibility(Notification.VISIBILITY_PRIVATE).setOngoing(true).setContentIntent(open).build()
            if (Build.VERSION.SDK_INT >= 29) startForeground(32,notification,ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
            else startForeground(32,notification)
            ready?.invoke(true); ready = null
        } catch (e: RuntimeException) {
            ready?.invoke(false); ready = null; session = null; stopSelf(startId)
        }
        return START_NOT_STICKY
    }
}
