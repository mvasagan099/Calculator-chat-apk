package app.calculatorspace.calculator_messenger

import android.app.*
import android.content.*
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.SystemClock

class CallForegroundService : Service() {
    companion object {
        var onEnd: ((String) -> Unit)? = null
        var ready: Pair<String, (Boolean) -> Unit>? = null
        var session: String? = null
        var callId: String? = null
        const val CHANNEL_ID = "active_call_v2"
        const val NOTIFICATION_ID = 31

        fun stop(context: Context, id: String) {
            if (session != id) return
            if (ready?.first == id) { ready?.second?.invoke(false); ready = null }
            ProjectionForegroundService.stop(context, id)
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
        val isVideo = intent.getBooleanExtra("video", false)
        val contactName = intent.getStringExtra("contactName")?.takeIf { it.isNotBlank() } ?: "Contact"
        val callType = if (isVideo) "Ongoing Video Call" else "Ongoing Voice Call"
        val startTime = intent.getLongExtra("startTime", System.currentTimeMillis())

        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Ongoing Calls",
                NotificationManager.IMPORTANCE_DEFAULT
            ).apply {
                description = "Shows active voice and video calls"
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                setSound(null, null)
                enableVibration(false)
            }
            manager.createNotificationChannel(channel)
        }

        val openIntent = Intent(this, MainActivity::class.java).apply {
            action = Intent.ACTION_MAIN
            addCategory(Intent.CATEGORY_LAUNCHER)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        val openPendingIntent = PendingIntent.getActivity(
            this,
            20,
            openIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val endIntent = Intent(this, EndCallReceiver::class.java)
            .setData(android.net.Uri.parse("calculator-call:$id"))
            .putExtra("id", id)
        val endPendingIntent = PendingIntent.getBroadcast(
            this,
            21,
            endIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val baseElapsed = if (startTime > 0) {
            SystemClock.elapsedRealtime() - (System.currentTimeMillis() - startTime)
        } else {
            SystemClock.elapsedRealtime()
        }

        val notification = Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(contactName)
            .setContentText(callType)
            .setSubText(if (isVideo) "Video" else "Voice")
            .setCategory(Notification.CATEGORY_CALL)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setContentIntent(openPendingIntent)
            .setUsesChronometer(true)
            .setWhen(baseElapsed)
            .setShowWhen(true)
            .addAction(
                Notification.Action.Builder(
                    null,
                    "End Call",
                    endPendingIntent
                ).build()
            )
            .build()

        try {
            if (Build.VERSION.SDK_INT >= 30) {
                var type = ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                if (isVideo) type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
                startForeground(NOTIFICATION_ID, notification, type)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            if (ready?.first == id) { ready?.second?.invoke(true); ready = null }
        } catch (e: RuntimeException) {
            if (ready?.first == id) { ready?.second?.invoke(false); ready = null }
            stop(this, id)
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
