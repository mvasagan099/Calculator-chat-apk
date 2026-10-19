package app.calculatorspace.calculator_messenger

import android.Manifest
import android.app.PictureInPictureParams
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Build
import android.os.Bundle
import android.util.Rational
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlin.math.sqrt

class MainActivity : FlutterFragmentActivity(), SensorEventListener {
    private var pinKdf: PinKdfChannel? = null
    private var permissionResult: MethodChannel.Result? = null
    private var mediaPicker: MediaPickerHandoff? = null
    private var callsChannel: MethodChannel? = null
    private var privacyChannel: MethodChannel? = null

    // Shake-to-lock detection
    private var sensorManager: SensorManager? = null
    private var accelerometer: Sensor? = null
    private var shakeToLockEnabled = true
    private var lastShakeTime: Long = 0
    private var shakeCount = 0

    override fun onCreate(savedInstanceState: Bundle?) {
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        super.onCreate(savedInstanceState)
        sensorManager = getSystemService(Context.SENSOR_SERVICE) as? SensorManager
        accelerometer = sensorManager?.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
        TelecomConnectionService.registerAccount(this)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        mediaPicker?.close()
        mediaPicker = MediaPickerHandoff(this, flutterEngine.dartExecutor.binaryMessenger)
        pinKdf?.close()
        pinKdf = PinKdfChannel(flutterEngine.dartExecutor.binaryMessenger)

        val calls = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "calculator_messenger/calls")
        callsChannel = calls
        CallForegroundService.onEnd = { id -> runOnUiThread { calls.invokeMethod("endCall", id) } }
        TelecomConnectionService.onAnswerCall = { id -> runOnUiThread { calls.invokeMethod("telecomAnswer", id) } }
        TelecomConnectionService.onRejectCall = { id -> runOnUiThread { calls.invokeMethod("telecomReject", id) } }

        calls.setMethodCallHandler { call, result ->
            when (call.method) {
                "requestPermissions" -> {
                    if (permissionResult != null) {
                        result.error("busy", "A permission request is already open", null)
                    } else {
                        val permissions = mutableListOf(Manifest.permission.RECORD_AUDIO)
                        if (call.argument<Boolean>("video") == true) permissions.add(Manifest.permission.CAMERA)
                        val missing = permissions.filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
                        if (missing.isEmpty()) result.success(null)
                        else {
                            permissionResult = result
                            requestPermissions(missing.toTypedArray(), 501)
                        }
                    }
                }
                "requestBluetooth" -> {
                    if (permissionResult != null) result.error("busy", "A permission request is already open", null)
                    else if (Build.VERSION.SDK_INT >= 31 && checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED) {
                        permissionResult = result
                        requestPermissions(arrayOf(Manifest.permission.BLUETOOTH_CONNECT), 502)
                    } else result.success(null)
                }
                "startCall" -> {
                    val id = call.argument<String>("id")
                    val callId = call.argument<String>("callId")
                    if (id == null || callId == null) result.error("invalid", "Call identity required", null)
                    else if (CallForegroundService.ready != null) result.error("busy", "Call service transition pending", null)
                    else {
                        CallForegroundService.ready = Pair(id) { success -> runOnUiThread {
                            if (success) result.success(null)
                            else result.error("service", "Call service unavailable; keep the app in the foreground", null)
                        } }
                        CallForegroundService.session = id
                        CallForegroundService.callId = callId
                        val contactName = call.argument<String>("contactName") ?: "Contact"
                        val startTime = (call.argument<Number>("startTime"))?.toLong() ?: System.currentTimeMillis()
                        val intent = Intent(this, CallForegroundService::class.java)
                            .putExtra("id", id)
                            .putExtra("callId", callId)
                            .putExtra("contactName", contactName)
                            .putExtra("startTime", startTime)
                            .putExtra("video", call.argument<Boolean>("video") ?: false)
                        try {
                            if (Build.VERSION.SDK_INT >= 26) startForegroundService(intent) else startService(intent)
                        } catch (e: RuntimeException) {
                            CallForegroundService.stop(this, id)
                        }
                    }
                }
                "projection" -> {
                    val id = call.argument<String>("id")
                    if (id == null) result.error("invalid", "Call identity required", null)
                    else if (call.argument<Boolean>("enabled") != true) {
                        ProjectionForegroundService.stop(this, id)
                        result.success(null)
                    } else if (CallForegroundService.session != id || ProjectionForegroundService.ready != null) {
                        result.error("unavailable", "Active call required", null)
                    } else {
                        ProjectionForegroundService.session = id
                        ProjectionForegroundService.ready = { success -> runOnUiThread {
                            if (success) result.success(null)
                            else result.error("projection", "Screen sharing service unavailable", null)
                        } }
                        try { startForegroundService(Intent(this, ProjectionForegroundService::class.java).putExtra("id", id)) }
                        catch(e: RuntimeException) { ProjectionForegroundService.stop(this, id) }
                    }
                }
                "stopCall" -> {
                    call.argument<String>("id")?.let { CallForegroundService.stop(this, it) }
                    result.success(null)
                }
                "enterPip" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        try {
                            val params = PictureInPictureParams.Builder()
                                .setAspectRatio(Rational(9, 16))
                                .build()
                            result.success(enterPictureInPictureMode(params))
                        } catch (_: Exception) {
                            result.success(false)
                        }
                    } else {
                        result.success(false)
                    }
                }
                "closePip" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N && isInPictureInPictureMode) {
                        moveTaskToBack(true)
                    }
                    result.success(null)
                }
                "startTelecomCall" -> {
                    val id = call.argument<String>("id") ?: ""
                    val name = call.argument<String>("name") ?: "Caller"
                    val video = call.argument<Boolean>("video") ?: false
                    TelecomConnectionService.startIncomingCall(this, id, name, video)
                    result.success(null)
                }
                "endTelecomCall" -> {
                    val id = call.argument<String>("id") ?: ""
                    TelecomConnectionService.endCall(id)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "calculator_messenger/launcher_icon")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "current" -> result.success(LauncherIconSwitcher.current(this))
                    "set" -> {
                        val selected = call.argument<String>("id")
                        if (selected == null) result.error("invalid", "Select a calculator icon", null)
                        else try { result.success(LauncherIconSwitcher.set(this, selected)) }
                        catch (_: IllegalArgumentException) {
                            result.error("invalid", "Unknown calculator icon", null)
                        } catch (_: Exception) {
                            result.error("launcher", "Android could not change the launcher icon", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        val privacy = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "calculator_messenger/privacy")
        privacyChannel = privacy
        privacy.setMethodCallHandler { call, result ->
            when (call.method) {
                "secure" -> {
                    window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    result.success(null)
                }
                "appIdentity" -> {
                    try {
                        result.success(InstalledAppIdentity.read(this))
                    } catch (_: Exception) { result.error("identity", "Package identity unavailable", null) }
                }
                "setShakeToLock" -> {
                    shakeToLockEnabled = call.arguments as? Boolean ?: true
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != 501 && requestCode != 502) return
        val result = permissionResult
        permissionResult = null
        if (grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }) result?.success(null)
        else result?.error("permission", if (requestCode == 502) "Nearby devices permission is required for Bluetooth routing" else "Microphone and requested camera permission are required", null)
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        callsChannel?.invokeMethod("pipChanged", isInPictureInPictureMode)
    }

    // Accelerometer Shake Detection
    override fun onSensorChanged(event: SensorEvent?) {
        if (!shakeToLockEnabled || event?.sensor?.type != Sensor.TYPE_ACCELEROMETER) return
        val x = event.values[0]
        val y = event.values[1]
        val z = event.values[2]
        val gX = x / SensorManager.GRAVITY_EARTH
        val gY = y / SensorManager.GRAVITY_EARTH
        val gZ = z / SensorManager.GRAVITY_EARTH
        val gForce = sqrt((gX * gX + gY * gY + gZ * gZ).toDouble()).toFloat()

        if (gForce > 2.5f) {
            val now = System.currentTimeMillis()
            if (lastShakeTime + 500 > now) {
                shakeCount++
                if (shakeCount >= 2) {
                    shakeCount = 0
                    lastShakeTime = now
                    runOnUiThread {
                        privacyChannel?.invokeMethod("quickLock", null)
                    }
                }
            } else {
                shakeCount = 1
                lastShakeTime = now
            }
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}

    @Suppress("DEPRECATION")
    override fun startActivityForResult(intent: Intent, requestCode: Int, options: Bundle?) {
        mediaPicker?.launching(intent, requestCode)
        super.startActivityForResult(intent, requestCode, options)
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        mediaPicker?.result(requestCode)
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onResume() {
        super.onResume()
        mediaPicker?.resumed()
        accelerometer?.let {
            sensorManager?.registerListener(this, it, SensorManager.SENSOR_DELAY_UI)
        }
    }

    override fun onPause() {
        mediaPicker?.paused()
        sensorManager?.unregisterListener(this)
        super.onPause()
    }

    override fun onStop() { mediaPicker?.stopped(); super.onStop() }
    override fun onUserLeaveHint() { mediaPicker?.invalidate(); super.onUserLeaveHint() }
    override fun onNewIntent(intent: Intent) { mediaPicker?.invalidate(); super.onNewIntent(intent) }

    override fun onDestroy() {
        sensorManager?.unregisterListener(this)
        mediaPicker?.close()
        mediaPicker = null
        pinKdf?.close()
        pinKdf = null
        permissionResult?.error("cancelled", "Activity closed", null)
        permissionResult = null
        CallForegroundService.onEnd = null
        TelecomConnectionService.onAnswerCall = null
        TelecomConnectionService.onRejectCall = null
        super.onDestroy()
    }
}
