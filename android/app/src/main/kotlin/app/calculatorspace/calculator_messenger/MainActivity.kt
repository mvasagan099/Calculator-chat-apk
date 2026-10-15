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
                "startCall" -> {
                    val id = call.argument<String>("id")
                    val callId = call.argument<String>("callId")
                    if (id == null || callId == null) result.error("invalid", "Call identity required", null)
                    else {
                        CallForegroundService.session = id
                        CallForegroundService.callId = callId
                        val intent = Intent(this, CallForegroundService::class.java)
                            .putExtra("id", id).putExtra("video", call.argument<Boolean>("video") ?: false)
                        try {
                            if (Build.VERSION.SDK_INT >= 26) startForegroundService(intent) else startService(intent)
                            result.success(null)
                        } catch (e: RuntimeException) {
                            CallForegroundService.stop(this, id)
                            result.error("service", "Call service unavailable; keep the app in the foreground", null)
                        }
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
        if (requestCode != 501) return
        val result = permissionResult
        permissionResult = null
        if (grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }) result?.success(null)
        else result?.error("permission", "Microphone and requested camera permission are required", null)
    }
    override fun onDestroy() {
        permissionResult?.error("cancelled", "Activity closed", null)
        permissionResult = null
        CallForegroundService.onEnd = null
        super.onDestroy()
    }
}
