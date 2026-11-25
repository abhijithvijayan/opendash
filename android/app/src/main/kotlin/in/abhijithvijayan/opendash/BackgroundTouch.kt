package `in`.abhijithvijayan.opendash

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.PowerManager

/// BOOL_TOUCH_STATUS once a second while an app opened from Apps is in
/// front. Flutter stops its own 1 Hz sender when the activity pauses; stock
/// HHMIC never pauses there (it hosts those apps in an ActivityView and
/// keeps counting their touches), so on stock the VCU's idle timer is fed
/// by the rider using the app.
///
/// The VCU locks a parked scooter 61 s after the last `true`, and treats
/// "no frame" the same as `false` (seen on a scooter: CarPlay in front,
/// no frames, PARK -> LOCK 61 s after the pause; 14 resumed samples lock
/// 61 s after the last `true`). So only the touches matter: they come from
/// the island's window ([DashIsland], its own touches and ACTION_OUTSIDE),
/// which is why this runs only while the island is up.
///
/// Main thread only.
object BackgroundTouch {
    private const val PERIOD_MS = 1000L
    private val main = Handler(Looper.getMainLooper())
    private var send: ((Boolean) -> Unit)? = null
    private var power: PowerManager? = null
    private var running = false
    private var touched = false
    private var lastSent: Boolean? = null

    /// Set from each island model; see [DashIsland].
    @Volatile var awake = false

    private val tick = object : Runnable {
        override fun run() {
            if (!running) return
            main.postDelayed(this, PERIOD_MS)
            // Screen off: the dashboard's own sender is paused then too, and
            // nothing should keep talking to the VCU overnight.
            if (power?.isInteractive == false) return
            // A touch the island saw, or Dart saying the rider is still
            // there on a page whose touches Android keeps to itself.
            val on = touched || (awake && !DashIsland.isStale)
            touched = false
            if (on != lastSent) Analytics.log("hhmis", "touch_status", mapOf("on" to on, "background" to true))
            lastSent = on
            send?.invoke(on)
        }
    }

    /// [sender] carries one frame to HHMIS; null when the bridge goes away.
    fun attach(sender: ((Boolean) -> Unit)?) {
        send = sender
    }

    fun start(context: Context) {
        if (running) return
        power = context.applicationContext.getSystemService(Context.POWER_SERVICE) as PowerManager
        running = true
        touched = false
        lastSent = null
        main.postDelayed(tick, PERIOD_MS)
    }

    fun stop() {
        awake = false
        running = false
        main.removeCallbacks(tick)
    }

    fun noteTouch() {
        touched = true
    }
}
