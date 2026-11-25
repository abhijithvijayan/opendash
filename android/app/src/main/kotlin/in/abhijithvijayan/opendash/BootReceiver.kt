package `in`.abhijithvijayan.opendash

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.util.Log

/// Safety net for boot: as the default HOME app Android starts OpenDash by
/// itself, but if the launcher choice was lost this brings the dashboard up
/// anyway. Android 10 may refuse the background start; that is logged, not
/// fatal.
///
/// If the rider has set a different launcher as HOME
/// (stock HHMIC, a file manager, whatever), honour that choice instead of
/// forcing our MainActivity in front.
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        if (!isCurrentHome(context)) {
            Log.i("BootReceiver", "not HOME; skipping dashboard start")
            return
        }
        try {
            context.startActivity(
                Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        } catch (e: RuntimeException) {
            Log.w("BootReceiver", "could not start dashboard: $e")
        }
    }

    private fun isCurrentHome(context: Context): Boolean {
        val homeIntent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
        val info = context.packageManager.resolveActivity(homeIntent, PackageManager.MATCH_DEFAULT_ONLY)
            ?: return false
        return info.activityInfo.packageName == context.packageName
    }
}
