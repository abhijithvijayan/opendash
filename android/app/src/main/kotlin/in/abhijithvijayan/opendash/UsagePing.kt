package `in`.abhijithvijayan.opendash

import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.security.MessageDigest
import kotlin.random.Random

/// Carries the anonymous weekly usage ping. The body, and every rule about
/// whether and when it is sent, come from Dart (`lib/state/usage_ping.dart`).
/// Only these headers: nothing about the rider or the scooter rides along.
///
/// Each ping carries a proof of work over its own text: a number that makes
/// the SHA-256 of `ping:number` start with [BITS] zero bits. Seconds of work
/// once a week here; hours for anyone faking thousands of pings. The server
/// (`server/usage`) checks it and takes each proof once.
object UsagePing {
    const val BITS = 22
    private val json = "application/json".toMediaType()

    fun request(url: String, body: String): Request = Request.Builder()
        .url(url)
        .header("User-Agent", "OpenDash")
        .post(body.toRequestBody(json))
        .build()

    /// The number that proves [ping], searched from a random start so two
    /// scooters with the same ping send different proofs.
    fun solve(ping: String, bits: Int = BITS): Long {
        val sha = MessageDigest.getInstance("SHA-256")
        val prefix = "$ping:".toByteArray()
        var n = Random.nextLong(0, 1L shl 40)
        while (true) {
            sha.update(prefix)
            if (leadingZeroBits(sha.digest(n.toString().toByteArray())) >= bits) return n
            n++
        }
    }

    fun leadingZeroBits(d: ByteArray): Int {
        var bits = 0
        for (b in d) {
            val v = b.toInt() and 0xff
            if (v == 0) {
                bits += 8
                continue
            }
            return bits + Integer.numberOfLeadingZeros(v) - 24
        }
        return bits
    }

    fun body(ping: String, bits: Int = BITS): String = """{"ping":${quote(ping)},"n":${solve(ping, bits)}}"""

    fun quote(s: String): String = buildString {
        append('"')
        for (c in s) when {
            c == '"' -> append("\\\"")
            c == '\\' -> append("\\\\")
            c < ' ' -> append("\\u%04x".format(c.code))
            else -> append(c)
        }
        append('"')
    }

    /// The HTTP status, or 0 for no answer.
    fun send(url: String, ping: String): Int = try {
        Net.quick.newCall(request(url, body(ping))).execute().use { it.code }
    } catch (_: Exception) {
        0
    }
}
