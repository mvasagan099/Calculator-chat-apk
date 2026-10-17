#!/usr/bin/env python3
"""Execute the actual Kotlin handoff with deterministic Android/channel doubles.

Requires JDK and kotlinc (KOTLINC may specify its path). No downloads, secrets,
Android device, Gradle invocation or signing. This is not an Android UI test.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
compiler = os.environ.get('KOTLINC') or shutil.which('kotlinc')
bundled = Path('/Applications/Android Studio.app/Contents/plugins/Kotlin/kotlinc/bin/kotlinc')
if not compiler and bundled.is_file():
    compiler = str(bundled)
if not compiler:
    raise SystemExit('Kotlin compiler unavailable; set KOTLINC to a trusted installed compiler.')

sources = {
    'Content.kt': r'''
package android.content
open class Context {
 companion object { const val RECEIVER_EXPORTED = 2 }
 var receiver: BroadcastReceiver? = null
 fun registerReceiver(receiver: BroadcastReceiver, filter: IntentFilter, flags: Int = 0) { this.receiver = receiver }
 fun unregisterReceiver(receiver: BroadcastReceiver) { this.receiver = null }
}
abstract class BroadcastReceiver { abstract fun onReceive(context: Context, intent: Intent) }
class IntentFilter { fun addAction(action: String) {} }
class Intent(var action: String? = null) {
 var type: String? = null
 var flags = 0
 val extras = mutableMapOf<String, Any>()
 @Suppress("UNCHECKED_CAST") fun <T> getParcelableExtra(name: String): T? = extras[name] as T?
 fun addFlags(value: Int) { flags = flags or value }
 companion object {
  const val ACTION_CLOSE_SYSTEM_DIALOGS = "android.intent.action.CLOSE_SYSTEM_DIALOGS"
  const val ACTION_SCREEN_OFF = "android.intent.action.SCREEN_OFF"
  const val ACTION_CHOOSER = "android.intent.action.CHOOSER"
  const val ACTION_GET_CONTENT = "android.intent.action.GET_CONTENT"
  const val ACTION_OPEN_DOCUMENT = "android.intent.action.OPEN_DOCUMENT"
  const val ACTION_PICK = "android.intent.action.PICK"
  const val EXTRA_INTENT = "android.intent.extra.INTENT"
  const val FLAG_ACTIVITY_NO_USER_ACTION = 0x00040000
 }
}
''',
    'Activity.kt': r'''
package android.app
import android.content.Context
class Activity : Context() { var focus = true; fun hasWindowFocus() = focus }
''',
    'Os.kt': r'''
package android.os
object Build { object VERSION { const val SDK_INT = 36 } }
class Looper { companion object { fun getMainLooper() = Looper() } }
class Handler(looper: Looper) {
 companion object { val tasks = mutableListOf<Runnable>(); fun expire() { val copy = tasks.toList(); tasks.clear(); copy.forEach { it.run() } } }
 fun postDelayed(task: Runnable, delay: Long) { tasks.add(task) }
 fun removeCallbacks(task: Runnable) { tasks.removeAll { it === task } }
}
''',
    'Channels.kt': r'''
package io.flutter.plugin.common
interface BinaryMessenger
class MethodCall(val method: String, val args: Map<String, String>) {
 @Suppress("UNCHECKED_CAST") fun <T> argument(name: String): T? = args[name] as T?
}
class Reply : MethodChannel.Result {
 var completed = false; var value: Any? = null
 override fun success(value: Any?) { check(!completed); completed = true; this.value = value }
 override fun notImplemented() { error("Unexpected method") }
}
class MethodChannel(messenger: BinaryMessenger, name: String) {
 companion object { lateinit var current: MethodChannel }
 init { current = this }
 val events = mutableListOf<Pair<String, Any?>>()
 var handler: ((MethodCall, Result) -> Unit)? = null
 interface Result { fun success(value: Any?); fun notImplemented() }
 fun setMethodCallHandler(handler: ((MethodCall, Result) -> Unit)?) { this.handler = handler }
 fun invokeMethod(method: String, value: Any?) { events.add(method to value) }
 fun send(method: String, vararg args: Pair<String, String>): Reply {
  val result = Reply(); handler!!(MethodCall(method, args.toMap()), result); return result
 }
}
''',
    'Tests.kt': r'''
import android.app.Activity
import android.content.Intent
import android.os.Handler
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import app.calculatorspace.calculator_messenger.MediaPickerHandoff

fun main() {
 var passed = 0
 fun run(name: String, body: (Activity, MediaPickerHandoff, MethodChannel) -> Unit) {
  val activity = Activity()
  val handoff = MediaPickerHandoff(activity, object : BinaryMessenger {})
  val channel = MethodChannel.current
  handoff.resumed()
  try { body(activity, handoff, channel); println("PASS: $name"); passed++ }
  finally { handoff.close() }
 }
 fun arm(channel: MethodChannel, kind: String = "image") { check(channel.send("arm", "token" to "one", "kind" to kind).value == true) }
 fun launch(handoff: MediaPickerHandoff, kind: String = "image") {
  val intent = Intent(if (kind == "camera") "android.media.action.IMAGE_CAPTURE" else Intent.ACTION_GET_CONTENT)
  intent.type = if (kind == "video") "video/*" else "image/*"
  handoff.launching(intent, 42)
  check(intent.flags and Intent.FLAG_ACTIVITY_NO_USER_ACTION != 0)
  handoff.paused(); handoff.stopped()
 }
 for (kind in listOf("image", "video", "camera", "document")) {
  run("$kind exact activity result", { _, handoff, channel ->
   arm(channel, kind); launch(handoff, kind); handoff.result(42); handoff.resumed()
   check(channel.send("finish", "token" to "one").value == true)
  })
 }
 for (signal in listOf(Intent.ACTION_CLOSE_SYSTEM_DIALOGS, Intent.ACTION_SCREEN_OFF)) {
  run("system leave signal $signal", { activity, handoff, channel ->
   arm(channel); launch(handoff)
   activity.receiver!!.onReceive(activity, Intent(signal))
   handoff.result(42); handoff.resumed()
   check(channel.events.contains("invalidated" to "one"))
   check(channel.send("finish", "token" to "one").value == false)
  })
 }
 run("wrong result and premature return rejected", { _, handoff, channel ->
  arm(channel); launch(handoff); handoff.result(99); handoff.resumed()
  check(channel.send("finish", "token" to "one").value == false)
 })
 run("manual cancel rejects late result", { _, handoff, channel ->
  arm(channel); launch(handoff); channel.send("cancel", "token" to "one")
  handoff.result(42); handoff.resumed()
  check(channel.send("finish", "token" to "one").value == false)
 })
 run("unknown activity cannot use handoff", { _, handoff, channel ->
  arm(channel); handoff.launching(Intent("android.intent.action.VIEW"), 42)
  check(channel.send("finish", "token" to "one").value == false)
 })
 run("second arm is refused; original result survives", { _, handoff, channel ->
  arm(channel)
  check(channel.send("arm", "token" to "two", "kind" to "video").value == false)
  launch(handoff); handoff.result(42); handoff.resumed()
  check(channel.send("finish", "token" to "one").value == true)
 })
 run("deadline rejects late activity result", { _, handoff, channel ->
  arm(channel); launch(handoff); Handler.expire(); handoff.result(42); handoff.resumed()
  check(channel.send("finish", "token" to "one").value == false)
 })
 run("finish waits for actual foreground resume", { _, handoff, channel ->
  arm(channel); launch(handoff); handoff.result(42)
  val result = channel.send("finish", "token" to "one")
  check(!result.completed); handoff.resumed(); check(result.value == true)
 })
 run("stopping before any matching launch invalidates", { _, handoff, channel ->
  arm(channel); handoff.paused(); handoff.stopped(); handoff.resumed()
  check(channel.send("finish", "token" to "one").value == false)
 })
 run("wrong token cannot finish or cancel current picker", { _, handoff, channel ->
  arm(channel); launch(handoff)
  channel.send("cancel", "token" to "stale")
  check(channel.send("finish", "token" to "stale").value == false)
  handoff.result(42); handoff.resumed()
  check(channel.send("finish", "token" to "one").value == true)
 })
 println("$passed native handoff cases passed; framework doubles, not Android UI verification")
}
''',
}

with tempfile.TemporaryDirectory(prefix='calculator-picker-') as temp:
    directory = Path(temp)
    for name, content in sources.items():
        (directory / name).write_text(content)
    artifact = directory / 'tests.jar'
    native = root / 'android/app/src/main/kotlin/app/calculatorspace/calculator_messenger/MediaPickerHandoff.kt'
    subprocess.run([compiler, '-nowarn', *map(str, directory.glob('*.kt')), str(native),
                    '-include-runtime', '-d', str(artifact)], check=True, timeout=60)
    subprocess.run(['java', '-jar', str(artifact)], check=True, timeout=30)
