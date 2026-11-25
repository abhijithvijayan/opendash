package `in`.abhijithvijayan.opendash.hhmis

import android.os.Binder
import android.os.IBinder
import android.os.Parcel
import android.util.Log

/// The reads the update callbacks need, so the layouts can be checked
/// without a real `Parcel` (`OtaDecoderTest`).
interface OtaReader {
    fun int(): Int
    fun long(): Long
    fun string(): String?
}

/// Parcel layouts of `com.android.hmiserverapp.IOTAInterface`, from the
/// HHMIS 4.6.14 stub (`IOTAInterface$Stub.onTransact`) and the parcelables
/// beside it. The enums (`OtaStates`, `DownloadReason`,
/// `InstallationReason`, `DownloadState`, `DownloadError`) each travel as
/// one int, their ordinal. Which string is which comes from the argument
/// order of HHMIS's own `IOTACallbacksImpl`.
///
/// Watching only: nothing here answers HOTA, and OpenDash has no call that
/// consents to a download or an install (see `HhmisProxy`).
object OtaDecoder {
    const val TX_INSTALL_PROGRESS = 1
    const val TX_FIRST_BOOT = 2
    const val TX_INSTALL_FAILED = 3
    const val TX_UP_TO_DATE = 4
    const val TX_UPDATE_AVAILABLE = 5
    const val TX_DOWNLOAD_DONE = 6
    const val TX_DOWNLOAD_STATUS = 7
    const val TX_RETRY_FAILED = 8

    fun decode(code: Int, r: OtaReader): Map<String, Any?>? = when (code) {
        TX_INSTALL_PROGRESS -> mapOf(
            "kind" to "install_progress",
            "state" to r.enum(),
            "status" to r.string(),
            "progress" to r.int(),
        )
        TX_FIRST_BOOT -> mapOf(
            "kind" to "first_boot",
            "autoDownload" to (r.int() != 0),
            "autoInstall" to (r.int() != 0),
        )
        TX_INSTALL_FAILED -> stateAndFour("install_failed", r)
        TX_UP_TO_DATE -> mapOf(
            "kind" to "up_to_date",
            "status" to r.string(),
            "version" to r.string(),
            "notes" to r.string(),
        )
        TX_UPDATE_AVAILABLE -> mapOf(
            "kind" to "available",
            "button" to (r.int() != 0),
            "reason" to r.enum(),
            "status" to r.string(),
            "version" to r.string(),
            "size" to r.string(),
            "notes" to r.string(),
        )
        TX_DOWNLOAD_DONE -> {
            val out = HashMap<String, Any?>()
            out["kind"] = "download_done"
            out["button"] = r.int() != 0
            out["reason"] = r.enum()
            out["version"] = r.string()
            downloadStatus(r, out)
            out["size"] = r.string()
            out["notes"] = r.string()
            out
        }
        TX_DOWNLOAD_STATUS -> {
            val out = HashMap<String, Any?>()
            out["kind"] = "download_status"
            out["state"] = r.enum()
            downloadStatus(r, out)
            out["version"] = r.string()
            out["size"] = r.string()
            out["notes"] = r.string()
            out["wifiOnly"] = r.int() != 0
            out
        }
        TX_RETRY_FAILED -> stateAndFour("retry_failed", r)
        else -> null
    }

    /// `(OtaStates, status, versionName, bundleSize, releaseNotes)`.
    private fun stateAndFour(kind: String, r: OtaReader) = mapOf(
        "kind" to kind,
        "state" to r.enum(),
        "status" to r.string(),
        "version" to r.string(),
        "size" to r.string(),
        "notes" to r.string(),
    )

    /// A parcelable argument: a presence flag, then the body.
    private fun OtaReader.enum(): Int? = if (int() != 0) int() else null

    /// A field written with `writeParcelable`: the class name, then the body.
    private fun OtaReader.namedEnum(): Int? = if (string() != null) int() else null

    /// `DownloadStatus.writeToParcel`. The download address, the file path
    /// and the download identifier are read past and dropped here: they
    /// never leave this function.
    private fun downloadStatus(r: OtaReader, out: HashMap<String, Any?>) {
        if (r.int() == 0) return
        r.int() // id
        r.string() // url
        r.string() // file
        out["dlBytes"] = r.long()
        out["dlTotal"] = r.long()
        out["dlState"] = r.namedEnum()
        out["dlError"] = r.namedEnum()
        out["dlProgress"] = r.int()
        r.long() // identifier
        r.int() // downloadOnEnqueue
        r.long() // etaInMilliSeconds
        r.long() // downloadedBytesPerSecond
        r.int() // autoRetryMaxAttempts
        r.int() // autoRetryAttempts
    }
}

/// Server side of `IOTAInterface`, handed to HHMIS with
/// `subscribeToUpdateTrigger`. The eight callbacks are two-way calls from
/// HHMIS, with HOTA waiting behind it: each is decoded, handed on, and
/// answered at once. Nothing here blocks, and nothing thrown gets out.
class HhmisOtaCallback(private val onNotice: (Map<String, Any?>) -> Unit) : Binder() {
    companion object {
        const val DESCRIPTOR = "com.android.hmiserverapp.IOTAInterface"
        private const val TAG = "HhmisOtaCallback"
    }

    init {
        attachInterface(null, DESCRIPTOR)
    }

    override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
        if (code < IBinder.FIRST_CALL_TRANSACTION || code > IBinder.LAST_CALL_TRANSACTION) {
            return super.onTransact(code, data, reply, flags)
        }
        try {
            data.enforceInterface(DESCRIPTOR)
            val notice = OtaDecoder.decode(code, object : OtaReader {
                override fun int() = data.readInt()
                override fun long() = data.readLong()
                override fun string(): String? = data.readString()
            })
            if (notice != null) onNotice(notice)
        } catch (e: RuntimeException) {
            // The exception text is not logged: it could quote the parcel.
            Log.w(TAG, "dropped update callback $code: ${e.javaClass.simpleName}")
        }
        reply?.writeNoException()
        return true
    }
}
