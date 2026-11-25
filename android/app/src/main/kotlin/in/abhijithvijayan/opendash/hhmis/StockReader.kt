package `in`.abhijithvijayan.opendash.hhmis

import android.content.Context
import android.util.Log
import `in`.abhijithvijayan.opendash.Analytics

/// Reads the numbering of the stock vehicle service installed on this
/// scooter from the service's own classes: the four lists by their enum
/// constants, the transaction codes from each interface's `Stub`. Nothing
/// is called on the service and nothing of it is started; the classes are
/// loaded into a class loader of their own and only their constants are
/// looked at.
///
/// All or nothing: a build where any part cannot be read gives null, and
/// the caller falls back to a recorded build.
// Works on a Gen 1 head unit on service 4.6.14: on a first start the read took 91 ms and gave the
// recorded 4.6.14 lists (`hhmis.kotlin_contract {source: read, checked: true}`). One scooter, one start.
object StockReader {
    const val PACKAGE = "com.android.hmiserverapp"
    private const val TAG = "StockReader"
    private const val PARCELABLES = "com.android.hmiserverapp.parcelables"

    fun version(context: Context): String = try {
        context.packageManager.getPackageInfo(PACKAGE, 0).versionName ?: ""
    } catch (_: Exception) {
        ""
    }

    fun read(context: Context, version: String): StockContract? {
        val started = System.currentTimeMillis()
        return try {
            val loader = context
                .createPackageContext(PACKAGE, Context.CONTEXT_INCLUDE_CODE or Context.CONTEXT_IGNORE_SECURITY)
                .classLoader
            fun names(cls: String): List<String> = loader.loadClass(cls).enumConstants!!.map { (it as Enum<*>).name }
            fun codes(cls: String): Map<String, Int> = loader.loadClass(cls).declaredFields
                .filter { it.name.startsWith("TRANSACTION_") }
                .associate { field ->
                    field.isAccessible = true
                    field.name.removePrefix("TRANSACTION_") to field.getInt(null)
                }
            val contract = StockContract(
                name = "",
                version = version,
                source = "read",
                checked = false,
                commands = names("$PARCELABLES.ClientCmd"),
                events = names("$PARCELABLES.ServerCmd"),
                states = names("$PARCELABLES.VehicleStates"),
                vehicleCommands = names("com.olaelectric.vehicleinterface.CommandFromVehicle"),
                calls = StockContract.INTERFACES.associateWith { codes("com.android.hmiserverapp.$it\$Stub") },
            )
            require(contract.calls.values.all { it.isNotEmpty() }) { "an interface with no transaction codes" }
            Analytics.log("hhmis", "kotlin_contract_read", mapOf("ok" to true, "took_ms" to System.currentTimeMillis() - started))
            contract
        } catch (e: Throwable) {
            Log.w(TAG, "could not read the stock service: $e")
            Analytics.log(
                "hhmis", "kotlin_contract_read",
                mapOf("ok" to false, "error" to e.javaClass.simpleName, "took_ms" to System.currentTimeMillis() - started),
            )
            null
        }
    }
}
