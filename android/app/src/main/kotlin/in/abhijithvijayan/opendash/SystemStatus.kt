package `in`.abhijithvijayan.opendash

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothProfile
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Handler
import android.os.Looper
import android.telephony.PhoneStateListener
import android.telephony.SignalStrength
import android.telephony.TelephonyManager
import java.io.File
import java.net.Inet4Address

/// `BluetoothDevice.isConnected()` is hidden but not blocked on API 29.
/// Null when the getter cannot be reached; the broadcasts then stand alone.
internal fun linked(device: BluetoothDevice): Boolean? = try {
    BluetoothDevice::class.java.getMethod("isConnected").invoke(device) as? Boolean
} catch (_: Exception) {
    null
}

/// False only when every paired classic phone answers "not connected";
/// null when there is none or one of them cannot be asked.
internal fun anyPhoneLinked(): Boolean? = try {
    val phones = BluetoothAdapter.getDefaultAdapter()?.bondedDevices.orEmpty().filter {
        it.bondState == BluetoothDevice.BOND_BONDED && it.type != BluetoothDevice.DEVICE_TYPE_LE
    }
    val states = phones.map { linked(it) }
    when {
        states.any { it == true } -> true
        states.isNotEmpty() && states.all { it == false } -> false
        else -> null
    }
} catch (_: SecurityException) {
    null
}

/// Wi-Fi and Bluetooth link state for the status bar, plus the identity
/// rows in Settings. HHMIS does not carry these (the stock UI reads them
/// from HSSS), so they come straight from the Android system services.
/// Changes are reported on the main thread.
///
/// Not readable by a non-system app on Android 10, so never reported: the
/// ICCID (READ_PRIVILEGED_PHONE_STATE), the adapter's Bluetooth MAC (always
/// 02:00:00:00:00:00), the Wi-Fi SSID and scan list (location permission).
class SystemStatus(private val context: Context, private val onChange: (String, Any?) -> Unit) {
    private companion object {
        const val ACTION_A2DP_SINK_CONNECTION = "android.bluetooth.a2dp-sink.profile.action.CONNECTION_STATE_CHANGED"
        const val ACTION_AVRCP_CONTROLLER_CONNECTION = "android.bluetooth.avrcp-controller.profile.action.CONNECTION_STATE_CHANGED"
        const val ACTION_HFP_CLIENT_CONNECTION = "android.bluetooth.headsetclient.profile.action.CONNECTION_STATE_CHANGED"
        const val RECHECK_MS = 4000L

        // The head unit is the sink: A2DP sink (11), AVRCP controller (12)
        // and HFP client (16) are what connected on a Gen 1. A2DP and
        // HEADSET are the source-side roles, kept in case a firmware uses them.
        const val SNAPSHOT_MS = 3000L
        val BT_PROFILES = intArrayOf(BluetoothProfile.A2DP, BluetoothProfile.HEADSET, 11, 12, 16)
        val BT_TRIGGERS = mapOf(
            BluetoothAdapter.ACTION_STATE_CHANGED to "adapter_state",
            BluetoothAdapter.ACTION_CONNECTION_STATE_CHANGED to "adapter_connection",
            BluetoothAdapter.ACTION_LOCAL_NAME_CHANGED to "name",
            BluetoothDevice.ACTION_ACL_CONNECTED to "acl_connected",
            BluetoothDevice.ACTION_ACL_DISCONNECTED to "acl_disconnected",
            BluetoothDevice.ACTION_BOND_STATE_CHANGED to "bond",
            ACTION_A2DP_SINK_CONNECTION to "a2dp_sink",
            ACTION_AVRCP_CONTROLLER_CONNECTION to "avrcp_controller",
            ACTION_HFP_CLIENT_CONNECTION to "hfp_client",
        )
    }

    private val main = Handler(Looper.getMainLooper())
    private val connectivity = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private val telephony = context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
    private val wifiNetworks = HashSet<Network>()
    private val wifiAddresses = HashMap<Network, String>()
    private val reported = HashMap<String, Any?>()

    var wifi = false
        private set
    var bluetooth = false
        private set

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            synchronized(wifiNetworks) { wifiNetworks.add(network) }
            main.post { setWifi(true) }
        }

        override fun onLinkPropertiesChanged(network: Network, link: LinkProperties) {
            val ip = link.linkAddresses.map { it.address }.firstOrNull { it is Inet4Address }?.hostAddress ?: ""
            val shown = synchronized(wifiNetworks) {
                wifiAddresses[network] = ip
                wifiAddresses.values.firstOrNull { it.isNotEmpty() } ?: ""
            }
            main.post { report("_ip", shown) }
        }

        override fun onLost(network: Network) {
            val (any, ip) = synchronized(wifiNetworks) {
                wifiNetworks.remove(network)
                wifiAddresses.remove(network)
                wifiNetworks.isNotEmpty() to (wifiAddresses.values.firstOrNull { it.isNotEmpty() } ?: "")
            }
            main.post {
                setWifi(any)
                report("_ip", ip)
            }
        }
    }

    /// Peers with an ACL link up, by address, oldest first. ACL_CONNECTED /
    /// ACL_DISCONNECTED are public broadcasts that reach any holder of
    /// BLUETOOTH; the public API has no "which device is connected" query
    /// outside a profile proxy.
    private val aclDevices = LinkedHashMap<String, BluetoothDevice>()

    /// What `MediaBridge` sees for itself: `media` while the phone's AVRCP
    /// session is playing, `hfp` while the HFP client has a device.
    private val witnesses = HashSet<String>()

    private val recheck = Runnable { refreshBluetooth("recheck") }
    private var lastVia: String? = null

    /// What is still connected a few seconds after the rider asked for a
    /// disconnect or switched Bluetooth off, for the log: the link to each
    /// paired phone as the adapter's own getter gives it, each profile's
    /// state, and what MediaBridge still vouches for. No name or address.
    fun snapshotAfter(reason: String) {
        main.postDelayed({
            val adapter = BluetoothAdapter.getDefaultAdapter()
            val phones = try {
                adapter?.bondedDevices.orEmpty().filter { isPhone(it) }
            } catch (_: SecurityException) {
                emptyList()
            }
            Analytics.log("bt", "snapshot", mapOf(
                "reason" to reason,
                "flag" to bluetooth,
                "via" to lastVia,
                "enabled" to (adapter?.isEnabled == true),
                "phones" to phones.size,
                "linked" to phones.count { isConnected(it) == true },
                "link_unknown" to phones.count { isConnected(it) == null },
                "profiles" to BT_PROFILES.associate { id ->
                    id.toString() to try { adapter?.getProfileConnectionState(id) ?: -1 } catch (_: RuntimeException) { -1 }
                },
                "witnesses" to witnesses.sorted(),
            ))
            refreshBluetooth("snapshot")
        }, SNAPSHOT_MS)
    }

    private val btReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val device = intent.getParcelableExtra<BluetoothDevice>(BluetoothDevice.EXTRA_DEVICE)
            when (intent.action) {
                BluetoothDevice.ACTION_ACL_CONNECTED -> device?.let { aclDevices[it.address] = it }
                BluetoothDevice.ACTION_ACL_DISCONNECTED -> device?.let { aclDevices.remove(it.address) }
            }
            refreshBluetooth(BT_TRIGGERS[intent.action] ?: "broadcast")
            // On a ride the adapter's CONNECTION_STATE_CHANGED fired when
            // AVRCP controller connected, 0.3 s before A2DP sink and 2.6 s
            // before HFP client, and nothing this receiver listened to came
            // after: the flag was read too early and stayed false.
            main.removeCallbacks(recheck)
            main.postDelayed(recheck, RECHECK_MS)
        }
    }

    /// 0-4, the scale of the status bar's bars. Needs no permission. Stock
    /// gets its level from HSSS `IConnectivityCallback.onSignalLevelChanged`
    /// (`SettingsInfoManager$1.smali`).
    private val signalListener = object : PhoneStateListener() {
        override fun onSignalStrengthsChanged(strength: SignalStrength) = report("_signal", strength.level)
    }

    fun start() {
        val request = NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build()
        connectivity.registerNetworkCallback(request, networkCallback)
        context.registerReceiver(btReceiver, IntentFilter().apply {
            addAction(BluetoothAdapter.ACTION_STATE_CHANGED)
            addAction(BluetoothAdapter.ACTION_CONNECTION_STATE_CHANGED)
            addAction(BluetoothAdapter.ACTION_LOCAL_NAME_CHANGED)
            addAction(BluetoothDevice.ACTION_ACL_CONNECTED)
            addAction(BluetoothDevice.ACTION_ACL_DISCONNECTED)
            addAction(BluetoothDevice.ACTION_BOND_STATE_CHANGED)
            // Hidden-API action names. Registering needs nothing and the
            // stack sends them to BLUETOOTH holders; `bt.link` records the
            // trigger, so a log shows whether this firmware delivers them.
            addAction(ACTION_A2DP_SINK_CONNECTION)
            addAction(ACTION_AVRCP_CONTROLLER_CONNECTION)
            addAction(ACTION_HFP_CLIENT_CONNECTION)
        })
        refreshBluetooth("start")
        try {
            telephony?.listen(signalListener, PhoneStateListener.LISTEN_SIGNAL_STRENGTHS)
        } catch (_: RuntimeException) {
        }
        Thread { readVersions() }.start()
    }

    fun stop() {
        try {
            telephony?.listen(signalListener, PhoneStateListener.LISTEN_NONE)
        } catch (_: RuntimeException) {
        }
        connectivity.unregisterNetworkCallback(networkCallback)
        main.removeCallbacks(recheck)
        try {
            context.unregisterReceiver(btReceiver)
        } catch (_: IllegalArgumentException) {
        }
    }

    private fun setWifi(on: Boolean) {
        if (wifi == on) return
        wifi = on
        onChange("_wifi", on)
    }

    /// Main thread. The activity is in front again: whatever changed while
    /// the stock dashboard was up is read again.
    fun refresh(trigger: String) = refreshBluetooth(trigger)

    /// Main thread. `MediaBridge` saw [source] (`media`, `hfp`) appear or go.
    fun witness(source: String, on: Boolean) {
        if (if (on) witnesses.add(source) else witnesses.remove(source)) refreshBluetooth(source)
    }

    /// "A phone is connected", from everything this sandbox can read, in
    /// order of trust: an ACL link to a bonded classic device, a connected
    /// profile, then `MediaBridge`'s witnesses. `_btVia` names the source
    /// holding the flag up, or the trigger that dropped it, and goes out
    /// just before `_bt` so Dart logs the pair.
    private fun refreshBluetooth(trigger: String) {
        val adapter = BluetoothAdapter.getDefaultAdapter()
        val enabled = adapter != null && adapter.isEnabled
        val bonded = try {
            if (enabled) adapter!!.bondedDevices.orEmpty().toList() else emptyList()
        } catch (_: SecurityException) {
            emptyList()
        }
        if (!enabled) aclDevices.clear()
        // The link state itself, where the hidden getter answers: covers a
        // phone connected before this process started and a missed
        // ACL_DISCONNECTED.
        for (device in bonded) {
            when (isConnected(device)) {
                true -> if (!aclDevices.containsKey(device.address)) aclDevices[device.address] = device
                false -> aclDevices.remove(device.address)
                null -> {}
            }
        }
        val phone = aclDevices.values.lastOrNull { isPhone(it) }
        // Every paired phone answered "not connected": what MediaBridge
        // vouches for is then left over from a phone that has gone. Once,
        // after the rider disconnected from the phone, its music
        // session stayed at "playing", which held this flag up, which kept
        // the dashboard at "connected" through nine presses of Disconnect.
        val phones = bonded.filter { isPhone(it) }
        val allDown = phones.isNotEmpty() && phones.all { isConnected(it) == false }
        val profile = enabled && try {
            BT_PROFILES.any { adapter!!.getProfileConnectionState(it) == BluetoothProfile.STATE_CONNECTED }
        } catch (_: RuntimeException) {
            false
        }
        val via = when {
            !enabled -> null
            phone != null -> "acl"
            profile -> "profile"
            allDown -> null
            else -> witnesses.minOrNull()
        }
        val on = via != null
        // Held up by a profile or a witness only: with one phone paired, it
        // is that phone; with several, the name stays blank.
        refreshBluetoothIdentity(adapter, bonded, if (on) phone ?: bonded.singleOrNull { isPhone(it) } else null)
        // What holds the flag up is logged when it changes too: "acl" giving
        // way to "media" with the flag still on was invisible in the log.
        if (bluetooth == on && via == lastVia) return
        val changed = bluetooth != on
        bluetooth = on
        lastVia = via
        Analytics.log("bt", "link", mapOf(
            "on" to on, "via" to via, "trigger" to trigger, "acl" to (phone != null), "profile" to profile,
            "witnesses" to witnesses.sorted(), "bonded" to bonded.size, "all_down" to allDown,
        ))
        if (!changed) return
        onChange("_btVia", via ?: trigger)
        onChange("_bt", on)
    }

    /// The name phones see, the connected phone's name and the paired list,
    /// all readable with the plain BLUETOOTH permission. Stock gets them
    /// from HSSS `IBluetoothSettings` (`BTInfoManager.smali`).
    private fun refreshBluetoothIdentity(adapter: BluetoothAdapter?, bonded: List<BluetoothDevice>, phone: BluetoothDevice?) {
        try {
            report("_btName", adapter?.name ?: "")
            report("_btBonded", bonded.map { it.name ?: it.address }.sorted())
            report("_btDevice", phone?.let { it.name ?: it.address } ?: "")
        } catch (_: SecurityException) {
        }
    }

    /// A bonded BR/EDR or dual-mode peer. BLE peers (the phone app, a key
    /// fob) raise the same ACL broadcasts, and an LE-only link is not a
    /// phone playing music. On first pairing the ACL comes up before the
    /// bond; BOND_STATE_CHANGED re-evaluates.
    private fun isPhone(device: BluetoothDevice): Boolean = try {
        device.bondState == BluetoothDevice.BOND_BONDED && device.type != BluetoothDevice.DEVICE_TYPE_LE
    } catch (_: SecurityException) {
        false
    }

    private fun isConnected(device: BluetoothDevice): Boolean? = linked(device)

    /// What stock's `VersionInfoManager.smali` reads: MoveOS is the first
    /// line of /vendor/etc/SW_version.txt (`readVersionInfo`), the vehicle
    /// software is data/ola/vsw.txt or /vendor/etc/vsw.txt
    /// (`readVersionIndoFromFile`), and the VDP version is the versionName
    /// of com.olaelectric.vehicleparser (`updateSWVersionInfo`). A file our
    /// sandbox cannot read stays blank and Settings hides its row.
    private fun readVersions() {
        val moveOs = firstLine("/vendor/etc/SW_version.txt")
        val vsw = firstLine("/data/ola/vsw.txt").ifEmpty { firstLine("/vendor/etc/vsw.txt") }
        val vdp = try {
            context.packageManager.getPackageInfo("com.olaelectric.vehicleparser", 0).versionName ?: ""
        } catch (_: Exception) {
            ""
        }
        // The stock service whose command and event numbers the hhmis
        // tables mirror; Dart holds the numbered commands on a version
        // it has not been checked against.
        val hhmis = try {
            context.packageManager.getPackageInfo("com.android.hmiserverapp", 0).versionName ?: ""
        } catch (_: Exception) {
            ""
        }
        main.post {
            report("_hhmis", hhmis)
            report("_moveOs", moveOs)
            report("_vsw", vsw)
            report("_vdp", vdp)
        }
    }

    private fun firstLine(path: String): String = try {
        File(path).useLines { it.firstOrNull()?.trim() ?: "" }
    } catch (_: Exception) {
        ""
    }

    /// Main thread only.
    private fun report(key: String, value: Any?) {
        if (reported.containsKey(key) && reported[key] == value) return
        reported[key] = value
        onChange(key, value)
    }
}
