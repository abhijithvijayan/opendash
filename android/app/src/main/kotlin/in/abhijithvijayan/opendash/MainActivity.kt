package `in`.abhijithvijayan.opendash

import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    companion object {
        /// The one live dashboard. Android can be made to create a second
        /// (seen on a scooter: the build was started by `am start` after an
        /// install, and the first return from another app made a new
        /// instance in the HOME task). The first then ran on behind it with
        /// its own Flutter engine for the rest of the session: a second
        /// greeting, two of every toast, and an island fed "Data not live"
        /// and a lock countdown by a dashboard that had lost the vehicle.
        private var current: java.lang.ref.WeakReference<MainActivity>? = null
    }

    private var retired = false

    /// Called on the older instance before the newer one builds its
    /// engine. It is marked, so that when it is destroyed it leaves alone
    /// what its successor has attached by then, and the activity ends.
    // TODO(second-instance): the retire ran once on the scooter and cost a 44 s reconnect;
    // the hand-over of the connection that replaces it is compiled, never run. After a flash, look for
    // app.second_instance followed by hhmis.kotlin_link_adopted {connected: true}, no second hhmis.bind_attempt,
    // and no frozen heartbeats between the live ones. Why Android makes the second instance is still inferred.
    private fun retire() {
        retired = true
        // Its bridges are let go in onDestroy, after the newer instance has
        // taken over the scooter connection (`VehicleChannel`): letting go
        // here left HHMIS without a client and it was gone for 44 s.
        finishAndRemoveTask()
    }

    private fun releaseBridges() {
        vehicle?.dispose()
        vehicle = null
        media?.dispose()
        media = null
        bluetooth?.dispose()
        bluetooth = null
    }

    private var vehicle: VehicleChannel? = null
    private var media: MediaBridge? = null
    private var bluetooth: BluetoothBridge? = null
    private var lastConfig: Configuration? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // Before the Flutter engine exists. An update that has started more
        // than three times without reaching a stable dashboard is taken as a
        // build that does not start: the stock dashboard is asked for first,
        // so it ends up in front even if what follows here crashes. Dart, if
        // it does come up, reads the same record and leaves stock alone.
        // TODO(update-fallback): the fall-back to the stock dashboard after three unconfirmed starts has not been tried
        // on the scooter (scripts/release.sh --crash-trial).
        val starts = UpdateRecord.noteStart(this)
        if (BuildConfig.CRASH_AT_START) throw IllegalStateException("OPENDASH_CRASH=kotlin: a build made to fail, for the fallback trial")
        if (starts > UpdateRecord.MAX_STARTS) {
            UpdateRecord.fallbackNote(this, starts)
            try {
                startActivity(
                    Intent().setClassName("com.olaelectric.hmiclient", "com.olaelectric.hmiclient.MainActivity")
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
            } catch (_: RuntimeException) {
            }
        }
        val older = current?.get()
        current = java.lang.ref.WeakReference(this)
        val replaced = older != null && older !== this && !older.isDestroyed
        if (replaced) older!!.retire()
        super.onCreate(savedInstanceState)
        // After the new engine is attached: before it, the line went to the
        // engine that was about to die and was lost.
        if (replaced) Analytics.log("app", "second_instance", mapOf("intent_flags" to "0x%08x".format(intent?.flags ?: 0)))
        // An instrument cluster never dims; this also keeps the stock
        // screensaver from taking the foreground.
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        lastConfig = Configuration(resources.configuration)
        Analytics.log("app", "activity_create", mapOf(
            "recreated" to (savedInstanceState != null),
            "intent_flags" to "0x%08x".format(intent?.flags ?: 0),
        ))
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        PlatformPlugin.register(this, flutterEngine)
        val channel = VehicleChannel(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        vehicle = channel
        media = MediaBridge(applicationContext, flutterEngine.dartExecutor.binaryMessenger, channel::bluetoothWitness)
        bluetooth = BluetoothBridge(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        DashIsland.attach(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        PlatformPlugin.unregister(flutterEngine)
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onResume() {
        super.onResume()
        if (retired) return
        DashIsland.foreground(true)
        // The phone is paired from the stock dashboard, with this activity
        // stopped behind it.
        vehicle?.refreshBluetooth("resume")
        media?.refresh()
        bluetooth?.refresh()
    }

    override fun onPause() {
        super.onPause()
        if (retired) return
        DashIsland.foreground(false)
    }

    // FlutterActivity's default onBackPressed calls
    // finish(), which exits the home launcher. The head unit then shows
    // a blank system home and the rider has no way back. A no-op keeps
    // the cluster in front; a modal or overlay that wants to close
    // handles its own back route from Flutter.
    @Deprecated("intentionally swallowed; the dashboard is HOME")
    override fun onBackPressed() {
        Analytics.log("app", "back_ignored", mapOf<String, Any?>())
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        Analytics.log("app", "new_intent", mapOf("intent_flags" to "0x%08x".format(intent.flags)))
    }

    // On the scooter every LOCK->PASSCODE transition tore the activity down
    // and rebuilt the Flutter engine in the same process. The manifest now
    // claims every config change; this records which one actually fired.
    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        val old = lastConfig
        lastConfig = Configuration(newConfig)
        val diff = old?.diff(newConfig) ?: 0
        Analytics.log("app", "config_changed", mapOf("changed" to configNames(diff), "mask" to "0x%08x".format(diff)))
    }

    override fun onDestroy() {
        val finishing = isFinishing
        val changing = isChangingConfigurations
        // A retired instance ends after its successor has attached: the
        // shared log bridge and the island are the successor's by then.
        if (!retired) {
            Analytics.detach()
            // Queued after detach, so it lands in the next engine's log.
            Analytics.log("app", "activity_destroy", mapOf("finishing" to finishing, "changing_config" to changing))
            DashIsland.detach()
            if (current?.get() === this) current = null
        } else {
            Analytics.log("app", "activity_destroy", mapOf("finishing" to finishing, "retired" to true))
        }
        releaseBridges()
        super.onDestroy()
    }

    private fun configNames(mask: Int): List<String> = listOf(
        ActivityInfo.CONFIG_MCC to "mcc",
        ActivityInfo.CONFIG_MNC to "mnc",
        ActivityInfo.CONFIG_LOCALE to "locale",
        ActivityInfo.CONFIG_TOUCHSCREEN to "touchscreen",
        ActivityInfo.CONFIG_KEYBOARD to "keyboard",
        ActivityInfo.CONFIG_KEYBOARD_HIDDEN to "keyboardHidden",
        ActivityInfo.CONFIG_NAVIGATION to "navigation",
        ActivityInfo.CONFIG_ORIENTATION to "orientation",
        ActivityInfo.CONFIG_SCREEN_LAYOUT to "screenLayout",
        ActivityInfo.CONFIG_UI_MODE to "uiMode",
        ActivityInfo.CONFIG_SCREEN_SIZE to "screenSize",
        ActivityInfo.CONFIG_SMALLEST_SCREEN_SIZE to "smallestScreenSize",
        ActivityInfo.CONFIG_DENSITY to "density",
        ActivityInfo.CONFIG_LAYOUT_DIRECTION to "layoutDirection",
        ActivityInfo.CONFIG_COLOR_MODE to "colorMode",
        ActivityInfo.CONFIG_FONT_SCALE to "fontScale",
    ).filter { mask and it.first != 0 }.map { it.second }
}
