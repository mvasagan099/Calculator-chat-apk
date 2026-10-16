package app.calculatorspace.calculator_messenger

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/** No KDF work on Android's UI thread, and no persistent plaintext PIN/cache. */
class PinKdfChannel(messenger: BinaryMessenger) {
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val channel = MethodChannel(messenger, "calculator_messenger/pin")

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "derive") {
                result.notImplemented()
            } else {
                val pin = call.argument<String>("pin")
                val salt = call.argument<ByteArray>("salt")
                val iterations = call.argument<Number>("iterations")?.toLong()
                if (pin == null || salt == null || iterations == null || iterations !in 1..Int.MAX_VALUE.toLong()) {
                    result.error("invalid", "Invalid PIN derivation input", null)
                } else {
                    val submitted = System.nanoTime()
                    executor.execute {
                        val started = System.nanoTime()
                        try {
                            val bytes = PinKdf.derive(pin, salt, iterations.toInt())
                            val elapsed = (System.nanoTime() - started) / 1000
                            main.post { result.success(mapOf(
                                "bytes" to bytes,
                                "derive_us" to elapsed,
                                "queue_us" to (started - submitted) / 1000
                            )) }
                        } catch (_: Exception) {
                            main.post { result.error("derivation", "PIN derivation unavailable", null) }
                        }
                    }
                }
            }
        }
    }

    fun close() {
        channel.setMethodCallHandler(null)
        executor.shutdown()
    }
}
