package `in`.abhijithvijayan.opendash

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import java.io.File

/// Kotlin-side entry to the Dart `AnalyticsLogger`: one-way `analytics`
/// calls on the platform channel. Events raised before Dart has installed
/// its handler (the HHMIS bind usually beats it) wait in a small queue
/// until `analyticsReady` arrives. Safe to call from any thread.
object Analytics {
    private const val MAX_QUEUE = 64
    private val main = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null
    private var ready = false
    private val queue = ArrayDeque<Map<String, Any?>>()

    fun attach(channel: MethodChannel) = main.post {
        this.channel = channel
        ready = false
    }

    fun ready() = main.post {
        ready = true
        while (queue.isNotEmpty()) send(queue.removeFirst())
    }

    fun detach() = main.post {
        channel = null
        ready = false
    }

    fun log(cat: String, evt: String, data: Map<String, Any?> = emptyMap()) {
        val event = mapOf(
            "cat" to cat,
            "evt" to evt,
            "data" to data + ("native_at" to System.currentTimeMillis()),
        )
        main.post {
            if (ready && channel != null) {
                send(event)
            } else {
                if (queue.size >= MAX_QUEUE) queue.removeFirst()
                queue.addLast(event)
            }
        }
    }

    private fun send(event: Map<String, Any?>) {
        try {
            channel?.invokeMethod("analytics", event)
        } catch (_: Exception) {
        }
    }

    /// "1" enforcing, "0" permissive, "unknown" when unreadable.
    fun selinux(): String = try {
        File("/sys/fs/selinux/enforce").readText().trim()
    } catch (_: Exception) {
        "unknown"
    }
}
