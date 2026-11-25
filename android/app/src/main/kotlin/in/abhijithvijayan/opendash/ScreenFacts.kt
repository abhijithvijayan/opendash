package `in`.abhijithvijayan.opendash

import android.app.Activity
import android.util.DisplayMetrics

/// The head unit's screen for the survey: its real size in pixels, the
/// density in use (what `wm density` set) and the one it ships with. The
/// install sets 160, which was chosen on Gen 1's 1280x768 screen.
object ScreenFacts {
    fun of(width: Int, height: Int, density: Int, defaultDensity: Int): Map<String, String> = mapOf(
        "screen_px" to "${width}x$height",
        "density" to "$density",
        "density_default" to "$defaultDensity",
    )

    fun of(activity: Activity): Map<String, String> = try {
        val m = DisplayMetrics()
        @Suppress("DEPRECATION")
        activity.windowManager.defaultDisplay.getRealMetrics(m)
        of(m.widthPixels, m.heightPixels, activity.resources.displayMetrics.densityDpi, DisplayMetrics.DENSITY_DEVICE_STABLE)
    } catch (_: Exception) {
        emptyMap()
    }
}
