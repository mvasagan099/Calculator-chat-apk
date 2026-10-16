package app.calculatorspace.calculator_messenger

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.Build
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private var permissionResult: MethodChannel.Result? = null
    override fun onCreate(savedInstanceState: Bundle?) {
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        super.onCreate(savedInstanceState)
    }
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val calls = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "calculator_messenger/calls")
        CallForegroundService.onEnd = { id -> runOnUiThread { calls.invokeMethod("endCall", id) } }
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
                        val intent = Intent(this, CallForegroundService::class.java)
                            .putExtra("id", id).putExtra("video", call.argument<Boolean>("video") ?: false)
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
                        ProjectionForegroundService.stop(this,id)
                        result.success(null)
                    } else if (CallForegroundService.session != id || ProjectionForegroundService.ready != null) {
                        result.error("unavailable", "Active call required", null)
                    } else {
                        ProjectionForegroundService.session = id
                        ProjectionForegroundService.ready = { success -> runOnUiThread {
                            if (success) result.success(null)
                            else result.error("projection", "Screen sharing service unavailable", null)
                        } }
                        try { startForegroundService(Intent(this,ProjectionForegroundService::class.java).putExtra("id",id)) }
                        catch(e: RuntimeException) { ProjectionForegroundService.stop(this,id) }
                    }
                }
                "stopCall" -> {
                    call.argument<String>("id")?.let { CallForegroundService.stop(this, it) }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "calculator_messenger/privacy")
            .setMethodCallHandler { call, result ->
                if (call.method == "secure") {
                    window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    result.success(null)
                } else result.notImplemented()
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
    override fun onDestroy() {
        permissionResult?.error("cancelled", "Activity closed", null)
        permissionResult = null
        CallForegroundService.onEnd = null
        super.onDestroy()
    }
}
