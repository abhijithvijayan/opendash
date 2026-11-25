package `in`.abhijithvijayan.opendash

import android.content.Context
import android.content.Intent
import android.provider.Settings

/// Bringing the dashboard back in front of an app opened from Apps. The
/// head unit has no navigation bar (qemu.hw.mainkeys=1), so the rider gets
/// there from the island ([DashIsland]), which replaced the "OpenDash" pill
/// this object used to draw. "Display over other apps" is what the island
/// needs, and also what lets Android 10 start our activity from the
/// background.
object ReturnOverlay {
    fun allowed(context: Context): Boolean = Settings.canDrawOverlays(context)

    /// CLEAR_TOP because the installer and the permission screens open
    /// inside our own task: with REORDER_TO_FRONT Android saw the task already
    /// in front and did nothing (four taps during an install). For an app in another task NEW_TASK brings ours forward.
    fun bringToFront(context: Context) {
        val intent = Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        context.startActivity(intent)
    }
}
