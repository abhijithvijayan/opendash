package `in`.abhijithvijayan.opendash

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import java.net.InetAddress
import java.net.UnknownHostException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import javax.net.SocketFactory
import okhttp3.Dns
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.dnsoverhttps.DnsOverHttps

/// How OpenDash reaches GitHub, and what it knows of the networks it is on.
///
/// On a scooter away from Wi-Fi, the mobile network's own DNS could not
/// resolve api.github.com and took 40 s to say so. OpenDash's own requests
/// therefore ask Cloudflare's resolver first, over HTTPS at its fixed
/// addresses (which needs no name lookup itself), and the network's DNS
/// only when Cloudflare cannot be reached. This is for OpenDash alone: the
/// rest of the head unit resolves names as before.
///
/// TODO(private-dns): move the whole head unit to Cloudflare with Android's
/// Private DNS setting (`settings put global private_dns_mode hostname`,
/// `private_dns_specifier one.one.one.one`), as a switch in Settings →
/// Developer with an off position that puts back what was there. Not yet:
/// in that mode Android does not fall back, so on a network that blocks
/// port 853, or whose own DNS cannot resolve the specifier, every app on
/// the head unit (Ola's services included) loses name resolution. Wait for
/// a `net.check` taken on mobile data with `cloudflare.dot: true`.
// TODO(mobile-data-github): on mobile data GitHub resolves and connects but HTTPS never answers; the cause is
// not known (DNS is ruled out). net.check and net.dns hold what has been tried.
object Net {
    /// 1.1.1.1 and its alternates, IPv4 then IPv6, as listed at
    /// https://one.one.one.one/dns/.
    val CLOUDFLARE_DNS = listOf("1.1.1.1", "1.0.0.1", "2606:4700:4700::1111", "2606:4700:4700::1001")
    private const val CLOUDFLARE_WITHIN_MS = 6_000L
    private const val SYSTEM_DNS_WITHIN_MS = 6_000L
    private const val SKIP_CLOUDFLARE_FOR_MS = 60_000L

    private val lookups = Executors.newCachedThreadPool { Thread(it, "opendash-dns").apply { isDaemon = true } }
    private val base = OkHttpClient()

    /// Cloudflare's resolver over HTTPS; [sockets] ties it to one network,
    /// for the connection check.
    fun cloudflare(sockets: SocketFactory? = null): DnsOverHttps {
        val client = base.newBuilder().connectTimeout(5, TimeUnit.SECONDS).readTimeout(5, TimeUnit.SECONDS)
        if (sockets != null) client.socketFactory(sockets)
        return DnsOverHttps.Builder()
            .client(client.build())
            .url("https://cloudflare-dns.com/dns-query".toHttpUrl())
            .bootstrapDnsHosts(CLOUDFLARE_DNS.map { InetAddress.getByName(it) })
            .build()
    }

    private val resolver by lazy { cloudflare() }
    @Volatile private var cloudflareFailedAt = 0L

    /// A lookup with a limit of its own: the network's resolver has none.
    private fun within(ms: Long, lookup: () -> List<InetAddress>): List<InetAddress> {
        val asked = lookups.submit(lookup)
        try {
            return asked.get(ms, TimeUnit.MILLISECONDS)
        } catch (e: Exception) {
            asked.cancel(true)
            throw (e.cause as? Exception) ?: e
        }
    }

    private val dns = object : Dns {
        override fun lookup(hostname: String): List<InetAddress> {
            val failedAt = cloudflareFailedAt
            var why = "skipped"
            if (failedAt == 0L || SystemClock.elapsedRealtime() - failedAt > SKIP_CLOUDFLARE_FOR_MS) {
                try {
                    return within(CLOUDFLARE_WITHIN_MS) { resolver.lookup(hostname) }.also {
                        if (failedAt != 0L) Analytics.log("net", "dns", mapOf("via" to "cloudflare", "ok" to true, "host" to hostname))
                        cloudflareFailedAt = 0
                    }
                } catch (e: Exception) {
                    cloudflareFailedAt = SystemClock.elapsedRealtime()
                    why = e.javaClass.simpleName + (e.message?.let { ": " + it.take(80) } ?: "")
                }
            }
            val started = SystemClock.elapsedRealtime()
            try {
                return within(SYSTEM_DNS_WITHIN_MS) { Dns.SYSTEM.lookup(hostname) }.also {
                    Analytics.log("net", "dns", mapOf(
                        "via" to "network", "ok" to true, "host" to hostname, "cloudflare" to why,
                        "addresses" to it.size, "took_ms" to SystemClock.elapsedRealtime() - started,
                    ))
                }
            } catch (e: Exception) {
                Analytics.log("net", "dns", mapOf(
                    "via" to "network", "ok" to false, "host" to hostname, "cloudflare" to why,
                    "error" to e.toString().take(120), "took_ms" to SystemClock.elapsedRealtime() - started,
                ))
                throw UnknownHostException(hostname).apply { initCause(e) }
            }
        }
    }

    /// For the small questions asked of GitHub's API: they answer in well
    /// under a second or not at all, and the rider is looking at a spinner.
    val quick: OkHttpClient = base.newBuilder().dns(dns)
        .connectTimeout(8, TimeUnit.SECONDS).readTimeout(12, TimeUnit.SECONDS).build()

    /// For a download: the read timeout is per read, so only a stalled
    /// transfer runs into it.
    val download: OkHttpClient = base.newBuilder().dns(dns)
        .connectTimeout(30, TimeUnit.SECONDS).readTimeout(60, TimeUnit.SECONDS).build()

    /// What is known of one network without asking anything of it. The head
    /// unit's own address is left out.
    fun facts(cm: ConnectivityManager, network: Network): Map<String, Any?>? {
        val caps = cm.getNetworkCapabilities(network) ?: return null
        val link: LinkProperties? = cm.getLinkProperties(network)
        return mapOf(
            "transport" to when {
                caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "mobile"
                else -> "other"
            },
            "default" to (network == cm.activeNetwork),
            "internet" to caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET),
            "validated" to caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED),
            "dns" to link?.dnsServers.orEmpty().mapNotNull { it.hostAddress },
            "private_dns" to (link?.privateDnsServerName ?: if (link?.isPrivateDnsActive == true) "auto" else "off"),
            // Which address families the link has (not the addresses), and
            // its packet size limit: an IPv6-only mobile link reaches IPv4
            // hosts through a translator, where large packets can be lost.
            "ipv4" to link?.linkAddresses.orEmpty().any { it.address is java.net.Inet4Address },
            "ipv6" to link?.linkAddresses.orEmpty().any { it.address is java.net.Inet6Address && !it.address.isLinkLocalAddress },
            "mtu" to (link?.mtu ?: 0),
            "interface" to link?.interfaceName,
        )
    }

    private var watching = false
    private var lastState: List<Map<String, Any?>>? = null

    /// Logs `net.state` at start and whenever a network comes, goes or is
    /// given different DNS servers, so the log says what the head unit was
    /// on at any moment and not only when something failed.
    fun watch(context: Context) {
        if (watching) return
        val cm = context.applicationContext.getSystemService(ConnectivityManager::class.java) ?: return
        watching = true
        val main = Handler(Looper.getMainLooper())
        val report = Runnable {
            val state = try {
                cm.allNetworks.mapNotNull { facts(cm, it) }
            } catch (_: RuntimeException) {
                return@Runnable
            }
            if (state != lastState) {
                lastState = state
                Analytics.log("net", "state", mapOf("networks" to state.map(::forLog)))
            }
        }
        // Changes arrive in bursts (capabilities, then link properties).
        fun changed() {
            main.removeCallbacks(report)
            main.postDelayed(report, 500)
        }
        try {
            cm.registerNetworkCallback(NetworkRequest.Builder().build(), object : ConnectivityManager.NetworkCallback() {
                override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) = changed()
                override fun onLinkPropertiesChanged(network: Network, link: LinkProperties) = changed()
                override fun onLost(network: Network) = changed()
            })
        } catch (_: RuntimeException) {
        }
        changed()
    }

    /// The log's copy of one network (as `LogPrivacy.networks` in Dart,
    /// which `test/log_privacy_test.dart` holds this to): an IPv6 DNS
    /// server keeps its first two groups, and a private DNS host name loses
    /// a first label that can be an account's own. The screen keeps both.
    fun forLog(network: Map<String, Any?>): Map<String, Any?> = network.mapValues { (key, value) ->
        when (key) {
            "dns" -> (value as? List<*>).orEmpty().map { a ->
                val s = a as? String ?: return@map a
                if (!s.contains(':')) s else s.split(':').filter { it.isNotEmpty() }.take(2).joinToString(":") + "::"
            }
            "private_dns" -> (value as? String)?.let { name ->
                val labels = name.split('.')
                if (name == "off" || name == "auto" || labels.size < 3) name else "*." + labels.drop(1).joinToString(".")
            }
            else -> value
        }
    }
}
