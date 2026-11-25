package `in`.abhijithvijayan.opendash.hsss

import android.content.Context
import android.util.Log
import `in`.abhijithvijayan.opendash.Analytics

/// Reads the numbering of the Bluetooth and profile services installed on
/// this scooter from their own classes, as `hhmis/StockReader` does for
/// the vehicle service: the transaction codes from each interface's
/// `Stub`, the profile values from their enum's constants. Nothing is
/// called on a service and nothing of it is started.
///
/// All or nothing per service: when any part cannot be read the answer is
/// null and the caller uses its built-in numbers. Blocks; never on the
/// main thread.
// The Bluetooth service works on a Gen 1 head unit on service 4.6.14: read in 94 ms with no number
// differing from the built-in ones (`bt.stock_calls {service: hsss, source: read, differs: []}`).
// TODO(stock-reader): the profile service has not been read on the head unit: no calls-setting write in that log.
object StockCallsReader {
    private const val TAG = "StockCallsReader"

    fun hsss(context: Context) = read(context, "hsss", HsssCalls.PACKAGE) { loader ->
        HsssCalls.INTERFACES.associateWith { codes(loader, "${HsssCalls.CLASSES}.$it\$Stub") }
    }

    fun hpms(context: Context) = read(context, "hpms", HpmsCalls.PACKAGE) { loader ->
        val cmds = loader.loadClass("${HpmsCalls.CLASSES}.${HpmsCalls.CMD}").enumConstants!!.map { (it as Enum<*>).name }
        mapOf(
            HpmsCalls.SERVICE to codes(loader, "${HpmsCalls.CLASSES}.${HpmsCalls.SERVICE}\$Stub"),
            HpmsCalls.CMD to cmds.withIndex().associate { it.value to it.index },
        )
    }

    private fun codes(loader: ClassLoader, cls: String): Map<String, Int> = loader.loadClass(cls).declaredFields
        .filter { it.name.startsWith("TRANSACTION_") }
        .associate { field ->
            field.isAccessible = true
            field.name.removePrefix("TRANSACTION_") to field.getInt(null)
        }

    private fun read(
        context: Context,
        service: String,
        pkg: String,
        tables: (ClassLoader) -> Map<String, Map<String, Int>>,
    ): Map<String, Map<String, Int>>? {
        val started = System.currentTimeMillis()
        var error: String? = null
        val found = try {
            val loader = context
                .createPackageContext(pkg, Context.CONTEXT_INCLUDE_CODE or Context.CONTEXT_IGNORE_SECURITY)
                .classLoader
            tables(loader).also { all -> require(all.values.all { it.isNotEmpty() }) { "a table with nothing in it" } }
        } catch (e: Throwable) {
            Log.w(TAG, "could not read $service: $e")
            error = e.javaClass.simpleName
            null
        }
        Analytics.log(
            "bt", "stock_calls_read",
            mapOf("service" to service, "ok" to (found != null), "error" to error, "took_ms" to System.currentTimeMillis() - started),
        )
        return found
    }
}
