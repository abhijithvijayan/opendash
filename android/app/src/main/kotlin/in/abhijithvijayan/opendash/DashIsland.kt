package `in`.abhijithvijayan.opendash

import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.Point
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.text.TextPaint
import android.text.TextUtils
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowManager
import android.view.animation.AccelerateInterpolator
import android.view.animation.DecelerateInterpolator
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.Random
import kotlin.math.abs
import kotlin.math.max

/// The dash island: a glass capsule over an app opened from Apps, showing
/// what Dart tells it to (`lib/state/dash_island.dart`). Every rule about
/// what may be shown or done is Dart's; this draws the model, reports taps
/// and reports what it actually showed.
///
/// Two things it decides alone, because they must hold when Dart cannot be
/// asked: it goes away when the display supply is cut ([hide] from
/// [VehicleChannel]), and it stops showing numbers when Dart stops talking.
///
/// Main thread only. The panel is 1280x768, so design pixels are physical
/// pixels: nothing here is in dp.
object DashIsland {
    private const val CHANNEL = "in.abhijithvijayan.opendash.island"
    private const val PREFS = "dash_island"
    private const val STALE_MS = 3_000L
    private const val GONE_MS = 10_000L
    private const val PERF_MS = 60_000L

    private val main = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null
    private var app: Context? = null
    private var view: IslandView? = null
    private var lastHeard = 0L
    private var shownAt = 0L
    private var stale = false

    /// Dart has gone quiet: nothing it said last is acted on.
    val isStale: Boolean get() = stale
    private var models = 0

    /// OpenDash's own activity is resumed. A model sent just before Dart
    /// heard about the resume must not put the window back (seen on a scooter:
    /// three islands of 11-27 ms over the dashboard).
    private var inFront = true
    private var faces: List<Typeface>? = null

    private val watch = object : Runnable {
        override fun run() {
            val v = view ?: return
            main.postDelayed(this, 1000)
            val silent = SystemClock.uptimeMillis() - lastHeard
            if (silent > GONE_MS) {
                hide("dart_silent")
            } else if (silent > STALE_MS && !stale) {
                stale = true
                v.stale = true
                v.invalidate()
                Analytics.log("island", "stale", mapOf("on" to true, "silent_ms" to silent))
                send("stale", mapOf("on" to true))
            }
        }
    }

    private val perf = object : Runnable {
        override fun run() {
            val v = view ?: return
            main.postDelayed(this, PERF_MS)
            Analytics.log("island", "perf", mapOf("draws" to v.draws, "max_draw_ms" to v.maxDrawNanos / 1_000_000.0, "models" to models))
            v.draws = 0
            v.maxDrawNanos = 0
            models = 0
        }
    }

    fun attach(context: Context, messenger: BinaryMessenger) {
        app = context.applicationContext
        main.post { faces(context.applicationContext) }
        // An engine that is being replaced no longer speaks for the island.
        channel?.setMethodCallHandler(null)
        channel = MethodChannel(messenger, CHANNEL).also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "set" -> @Suppress("UNCHECKED_CAST") set(call.arguments as Map<String, Any?>)
                    "hide" -> hide(call.argument<String>("reason") ?: "dart")
                    "ping" -> heard()
                }
                result.success(null)
            }
        }
    }

    fun foreground(resumed: Boolean) {
        inFront = resumed
        if (resumed) hide("foreground")
    }

    /// Loading the variable font took most of the 650 ms the first island
    /// needed on the scooter; later ones took 100 ms.
    private fun faces(context: Context): List<Typeface> = faces ?: listOf("'wdth' 125, 'wght' 600", "'wdth' 100, 'wght' 600", "'wdth' 100, 'wght' 400").map {
        try {
            Typeface.Builder(context.assets, "flutter_assets/assets/fonts/Archivo-Variable.ttf").setFontVariationSettings(it).build()
        } catch (_: Exception) {
            Typeface.DEFAULT_BOLD
        }
    }.also { faces = it }

    fun detach() {
        hide("engine_gone")
        channel?.setMethodCallHandler(null)
        channel = null
    }

    private fun heard() {
        lastHeard = SystemClock.uptimeMillis()
        if (stale) {
            stale = false
            view?.let {
                it.stale = false
                it.invalidate()
            }
            Analytics.log("island", "stale", mapOf("on" to false))
            send("stale", mapOf("on" to false))
        }
    }

    private fun set(model: Map<String, Any?>) {
        val context = app ?: return
        heard()
        models++
        // Dart's word that the rider is still there (dash_island.dart,
        // `_present`); never while the dashboard itself is in front.
        BackgroundTouch.awake = !inFront && model["awake"] == true
        // Normally the island only shows over another app; `over_self` lets it
        // draw over OpenDash's own screen too (the Diagnostics tab, which
        // covers the dial while riding). TYPE_APPLICATION_OVERLAY
        // floats above our activity, so the same view renders on top.
        if (inFront && model["over_self"] != true) return
        val existing = view
        if (existing != null) {
            existing.show(model)
            return
        }
        if (!Settings.canDrawOverlays(context)) {
            Analytics.log("island", "hide", mapOf("reason" to "no_permission"))
            send("hidden", mapOf("reason" to "no_permission"))
            return
        }
        val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val v = IslandView(context, wm)
        try {
            v.addTo(model)
        } catch (e: Exception) {
            Analytics.log("island", "hide", mapOf("reason" to "add_failed", "error" to e.toString()))
            send("hidden", mapOf("reason" to "add_failed"))
            return
        }
        view = v
        shownAt = SystemClock.uptimeMillis()
        BackgroundTouch.start(context)
        IslandService.start(context)
        main.postDelayed(watch, 1000)
        main.postDelayed(perf, PERF_MS)
        Analytics.log("island", "show", mapOf("app" to model["app"], "snap" to v.snap))
    }

    fun hide(reason: String) {
        val v = view ?: return
        val context = app ?: return
        view = null
        stale = false
        main.removeCallbacks(watch)
        main.removeCallbacks(perf)
        BackgroundTouch.stop()
        IslandService.stop(context)
        v.remove()
        Analytics.log("island", "hide", mapOf("reason" to reason, "shown_ms" to SystemClock.uptimeMillis() - shownAt))
        send("hidden", mapOf("reason" to reason))
    }

    private fun send(method: String, args: Map<String, Any?>) {
        try {
            channel?.invokeMethod(method, args)
        } catch (_: Exception) {
        }
    }

    /// Kotlin believes the island is up, and Android says the window is not.
    private fun lostWindow() {
        if (view == null) return
        Analytics.log("island", "hide", mapOf("reason" to "system"))
        send("hidden", mapOf("reason" to "system"))
    }

    private fun tapped(id: String) {
        val context = app ?: return
        if (stale) {
            // Dart is not answering: the only thing a tap can safely do.
            try {
                ReturnOverlay.bringToFront(context)
            } catch (_: Exception) {
            }
            return
        }
        send("tap", mapOf("id" to id))
    }

    @SuppressLint("ViewConstructor")
    private class IslandView(context: Context, private val wm: WindowManager) : View(context) {
        companion object {
            const val M = 12f
            const val EDGE = 16
            const val ROW = 72f
            // One width whether the boot button is there or not: at 440 and
            // 508 the island changed size at every stop and start, and 550
            // (room for messages in the row) was too wide.
            // Messages go on a line of their own, [SUB] high.
            const val W_COLLAPSED = 460f
            const val SUB = 44f
            const val W_PILL = 220f
            const val BOOT = 68f
            const val W_ATTENTION = 560f
            const val W_ACTION = 600f
            const val W_EXPANDED = 680f
            const val H_ATTENTION = 96f
            const val H_ACTION = 120f
            const val H_EXPANDED = 220f
        }

        var stale = false
        var draws = 0
        var maxDrawNanos = 0L
        var snap = "tc"

        private var model: Map<String, Any?> = emptyMap()
        private var seq = -1
        private var reportedSeq = -1
        private val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        private val screen = Point().also { @Suppress("DEPRECATION") wm.defaultDisplay.getRealSize(it) }
        private val params = WindowManager.LayoutParams(
            0, 0,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            // WATCH_OUTSIDE_TOUCH: touches on the app underneath still go to
            // it; we only learn that one happened.
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_WATCH_OUTSIDE_TOUCH or
                WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED,
            PixelFormat.TRANSLUCENT,
        ).apply { gravity = Gravity.TOP or Gravity.START }

        // The island's own size, animated; the window is only ever resized
        // at the two ends of an animation.
        private var w = W_COLLAPSED
        private var h = ROW
        private var targetW = W_COLLAPSED
        private var targetH = ROW
        private var grow = 1f
        private var destW = W_COLLAPSED
        private var destH = ROW
        private var blink: ValueAnimator? = null
        private var blinkOn = true
        private var animator: ValueAnimator? = null
        private var pulse: ValueAnimator? = null
        private var pulseAlpha = 1f

        private val rect = RectF()
        private val tmp = RectF()
        private val icon = RectF()
        private val path = Path()
        private val hits = ArrayList<Pair<RectF, String>>()
        private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
        private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }
        private val grain = Paint().apply { shader = BitmapShader(noise(), Shader.TileMode.REPEAT, Shader.TileMode.REPEAT) }
        private val numeral = faces(context)[0]
        private val label = faces(context)[1]
        private val caption = faces(context)[2]
        private val text = TextPaint(Paint.ANTI_ALIAS_FLAG).apply { fontFeatureSettings = "tnum" }
        private var gradientFor = -1f
        private var glass: Shader? = null
        private var edge: Shader? = null
        private var glassLight = false

        private var downX = 0f
        private var downY = 0f
        private var startX = 0
        private var startY = 0
        private var dragging = false
        private var travelled = 0f
        private val slop = ViewConfiguration.get(context).scaledTouchSlop

        private fun noise(): Bitmap {
            val size = 64
            val random = Random(7)
            val pixels = IntArray(size * size) { Color.argb(random.nextInt(18), 255 * random.nextInt(2), 255 * random.nextInt(2), 255 * random.nextInt(2)) }
            return Bitmap.createBitmap(pixels, size, size, Bitmap.Config.ARGB_8888)
        }

        fun addTo(first: Map<String, Any?>) {
            model = first
            seq = int("seq")
            snap = prefs.getString("snap_${first["app"]}", "tc") ?: "tc"
            measureTarget()
            w = targetW
            h = targetH
            destW = w
            destH = h
            place(w, h)
            wm.addView(this, params)
        }

        fun remove() {
            animator?.cancel()
            pulse?.cancel()
            blink?.cancel()
            try {
                wm.removeView(this)
            } catch (_: Exception) {
            }
        }

        fun show(next: Map<String, Any?>) {
            val app = model["app"]
            model = next
            seq = int("seq")
            if (next["app"] != app) snap = prefs.getString("snap_${next["app"]}", "tc") ?: "tc"
            measureTarget()
            // Against where the animation is going, not where it is: a speed
            // update mid-grow restarted it every time, and two
            // critical alerts were not up within their second.
            if (targetW != destW || targetH != destH) resize() else if (next["app"] != app) relayout(w, h)
            val blinking = (bool("left") || bool("right")) && !stale
            if (blinking && blink == null) {
                blink = ValueAnimator.ofInt(0, 1).apply {
                    duration = 700
                    repeatCount = ValueAnimator.INFINITE
                    addUpdateListener {
                        val on = it.animatedFraction < 0.5f
                        if (on != blinkOn) {
                            blinkOn = on
                            invalidate()
                        }
                    }
                    start()
                }
            } else if (!blinking) {
                blink?.cancel()
                blink = null
                blinkOn = true
            }
            val critical = (att()?.get("priority") == "critical")
            if (critical && pulse == null) {
                pulse = ValueAnimator.ofFloat(1f, 0.55f).apply {
                    duration = 600
                    repeatMode = ValueAnimator.REVERSE
                    repeatCount = ValueAnimator.INFINITE
                    addUpdateListener {
                        pulseAlpha = it.animatedValue as Float
                        invalidate()
                    }
                    start()
                }
            } else if (!critical) {
                pulse?.cancel()
                pulse = null
                pulseAlpha = 1f
            }
            invalidate()
        }

        private fun att(): Map<*, *>? = model["att"] as? Map<*, *>

        private fun measureTarget() {
            val a = att()
            when {
                a != null -> {
                    val action = a["action"] != null
                    targetW = if (action) W_ACTION else W_ATTENTION
                    targetH = ROW + if (action) H_ACTION else H_ATTENTION
                }
                model["state"] == "expanded" -> {
                    targetW = W_EXPANDED
                    targetH = ROW + H_EXPANDED
                }
                else -> {
                    targetW = if (bool("pill")) W_PILL else W_COLLAPSED
                    targetH = ROW + if (model["sub"] != null) SUB else 0f
                }
            }
        }

        /// One resize to the larger of the two sizes, the animation inside
        /// it, then one more to the final size: a resize per frame is a
        /// relayout and a new buffer each time.
        private fun resize() {
            animator?.cancel()
            val fromW = w
            val fromH = h
            val toW = targetW
            val toH = targetH
            destW = toW
            destH = toH
            val growing = toW * toH >= fromW * fromH
            relayout(max(fromW, toW), max(fromH, toH))
            animator = ValueAnimator.ofFloat(0f, 1f).apply {
                duration = if (growing) 250 else 200
                interpolator = if (growing) DecelerateInterpolator(1.5f) else AccelerateInterpolator(1.5f)
                addUpdateListener {
                    val t = it.animatedValue as Float
                    w = fromW + (toW - fromW) * t
                    h = fromH + (toH - fromH) * t
                    grow = if (growing) t else 1f - t
                    invalidate()
                    if (it.animatedFraction >= 1f) {
                        grow = 1f
                        relayout(toW, toH)
                    }
                }
                // The frame that reports what was drawn must come after the
                // animation has ended.
                addListener(object : AnimatorListenerAdapter() {
                    override fun onAnimationEnd(animation: Animator) = invalidate()
                })
                start()
            }
        }

        private fun place(width: Float, height: Float) {
            val ww = (width + 2 * M).toInt()
            val wh = (height + 2 * M).toInt()
            params.width = ww
            params.height = wh
            params.x = when (snap[1]) {
                'l' -> EDGE - M.toInt()
                'r' -> screen.x - EDGE - ww + M.toInt()
                else -> (screen.x - ww) / 2
            }
            params.y = if (snap[0] == 'b') screen.y - EDGE - wh + M.toInt() else EDGE - M.toInt()
        }

        private fun relayout(width: Float, height: Float) {
            place(width, height)
            try {
                wm.updateViewLayout(this, params)
            } catch (_: Exception) {
            }
        }

        override fun onWindowVisibilityChanged(visibility: Int) {
            super.onWindowVisibilityChanged(visibility)
            if (visibility != VISIBLE && isAttachedToWindow) lostWindow()
        }

        private fun int(key: String): Int = (model[key] as? Number)?.toInt() ?: 0
        private fun bool(key: String): Boolean = model[key] == true
        private fun str(key: String): String = model[key] as? String ?: ""
        private fun alpha(color: Int, a: Float): Int = Color.argb((Color.alpha(color) * a).toInt(), Color.red(color), Color.green(color), Color.blue(color))

        override fun onDraw(canvas: Canvas) {
            val started = System.nanoTime()
            val light = bool("light")
            val bone = int("bone")
            val ash = int("ash")
            val hair = alpha(bone, 0.12f)

            // The island keeps its snapped edge while it changes size.
            val left = when (snap[1]) {
                'l' -> M
                'r' -> width - M - w
                else -> (width - w) / 2f
            }
            val top = if (snap[0] == 'b') height - M - h else M
            rect.set(left, top, left + w, top + h)
            val radius = if (model["state"] == "expanded") 32f else 36f
            hits.clear()

            if (glass == null || gradientFor != h || glassLight != light) {
                gradientFor = h
                glassLight = light
                glass = if (light) {
                    LinearGradient(0f, 0f, 0f, h, Color.argb(230, 255, 255, 255), Color.argb(219, 238, 241, 245), Shader.TileMode.CLAMP)
                } else {
                    LinearGradient(0f, 0f, 0f, h, Color.argb(214, 30, 35, 44), Color.argb(224, 12, 15, 20), Shader.TileMode.CLAMP)
                }
                val (a0, a1, a2, a3) = if (light) listOf(255, 128, 51, 178) else listOf(87, 20, 8, 31)
                edge = LinearGradient(
                    0f, 0f, 0f, h,
                    intArrayOf(Color.argb(a0, 255, 255, 255), Color.argb(a1, 255, 255, 255), Color.argb(a2, 255, 255, 255), Color.argb(a3, 255, 255, 255)),
                    floatArrayOf(0f, 0.4f, 0.72f, 1f), Shader.TileMode.CLAMP,
                )
            }

            canvas.save()
            canvas.translate(0f, rect.top)
            tmp.set(rect.left, 0f, rect.right, h)
            fill.shader = glass
            fill.setShadowLayer(8f, 0f, 4f, if (light) Color.argb(56, 10, 15, 25) else Color.argb(77, 0, 0, 0))
            canvas.drawRoundRect(tmp, radius, radius, fill)
            fill.clearShadowLayer()
            fill.shader = null
            path.rewind()
            path.addRoundRect(tmp, radius, radius, Path.Direction.CW)
            canvas.save()
            canvas.clipPath(path)
            canvas.drawRect(tmp, grain)
            canvas.restore()
            stroke.shader = null
            stroke.strokeWidth = 1f
            stroke.color = if (light) Color.argb(36, 26, 29, 35) else Color.argb(115, 0, 0, 0)
            canvas.drawRoundRect(tmp, radius, radius, stroke)
            tmp.inset(1.25f, 1.25f)
            stroke.shader = edge
            stroke.strokeWidth = 1.5f
            canvas.drawRoundRect(tmp, radius - 1.25f, radius - 1.25f, stroke)
            stroke.shader = null
            canvas.restore()

            val a = att()
            if (a != null) {
                val critical = a["priority"] == "critical"
                stroke.strokeWidth = 2f
                stroke.color = alpha(if (critical) int("critical") else if (a["priority"] == "warning") int("warning") else hair, if (critical) pulseAlpha else 1f)
                canvas.drawRoundRect(rect, radius, radius, stroke)
            }

            // With the bottom edge snapped the status row stays nearest the
            // edge and the island grows upward.
            val rowTop = if (snap[0] == 'b') rect.bottom - ROW else rect.top
            val extraTop = if (snap[0] == 'b') rect.top else rect.top + ROW
            drawRow(canvas, rect.left, rowTop, bone, ash, hair)
            if (h > ROW + 1f) {
                fill.color = hair
                val y = if (snap[0] == 'b') rowTop else extraTop
                canvas.drawRect(rect.left + 1, y, rect.right - 1, y + 1, fill)
                canvas.save()
                canvas.clipRect(rect.left, extraTop, rect.right, extraTop + h - ROW)
                val fade = ((grow - 0.5f) * 2f).coerceIn(0f, 1f)
                canvas.saveLayerAlpha(rect.left, extraTop, rect.right, extraTop + h - ROW, (fade * 255).toInt())
                if (a != null) drawAttention(canvas, a, rect.left, extraTop, bone, ash, hair)
                else if (model["state"] == "expanded") drawExpanded(canvas, rect.left, extraTop, bone, ash, hair)
                else (model["sub"] as? Map<*, *>)?.let { drawSub(canvas, it, rect.left, extraTop, bone, hair) }
                canvas.restore()
                canvas.restore()
            }

            draws++
            maxDrawNanos = max(maxDrawNanos, System.nanoTime() - started)
            if (seq != reportedSeq) {
                reportedSeq = seq
                val drawn = seq
                post { if (isAttachedToWindow && windowVisibility == VISIBLE) send("shown", mapOf("seq" to drawn, "state" to model["state"])) }
            }
        }

        private fun drawRow(canvas: Canvas, x0: Float, y0: Float, bone: Int, ash: Int, hair: Int) {
            val mid = y0 + ROW / 2
            hits.add(RectF(x0, y0, x0 + w, y0 + ROW) to "row")
            if (bool("pill")) {
                // Nothing to show over the stock dashboard or one of
                // Android's own screens: only the way back.
                text.typeface = label
                text.textSize = 24f
                text.color = if (stale) ash else bone
                backLabel(canvas, x0 + w / 2, mid, 24f, text.color)
                return
            }
            val warning = int("warning")
            arrow(canvas, x0 + 34f, mid, true, if (bool("left") && !stale && blinkOn) warning else alpha(bone, 0.16f))
            arrow(canvas, x0 + w - 34f, mid, false, if (bool("right") && !stale && blinkOn) warning else alpha(bone, 0.16f))

            var x = x0 + 62f
            fill.color = if (stale) ash else int("accent")
            tmp.set(x, mid - 20, x + 5, mid + 20)
            canvas.drawRoundRect(tmp, 2.5f, 2.5f, fill)
            x += 17f

            text.typeface = numeral
            text.textSize = 50f
            text.color = if (stale) ash else bone
            val speed = if (stale) "––" else str("speed")
            canvas.drawText(speed, x, mid + 18f, text)
            x += text.measureText(speed) + 7f
            val unit = if (stale) "" else str("unit")
            var unitWidth = 0f
            if (unit.isNotEmpty()) {
                text.typeface = caption
                text.textSize = 17f
                text.color = ash
                canvas.drawText(unit, x, mid + 18f, text)
                unitWidth = text.measureText(unit)
            }
            // The drive mode in words, above the unit, in the mode's colour.
            val mode = if (stale) "" else str("mode")
            if (mode.isNotEmpty()) {
                text.typeface = label
                text.textSize = 13f
                text.color = int("accent")
                canvas.drawText(mode, x, mid - 3f, text)
                unitWidth = maxOf(unitWidth, text.measureText(mode))
            }
            x += unitWidth
            x += 16f
            fill.color = hair
            canvas.drawRect(x, mid - 17, x + 1, mid + 17, fill)
            x += 17f

            val soc = model["soc"] as? Number
            if (soc != null && !stale) {
                stroke.strokeWidth = 2f
                stroke.color = ash
                tmp.set(x, mid - 8, x + 30, mid + 8)
                canvas.drawRoundRect(tmp, 4f, 4f, stroke)
                fill.color = ash
                canvas.drawRect(x + 31, mid - 3, x + 34, mid + 3, fill)
                fill.color = int("socColor")
                tmp.set(x + 3, mid - 5, x + 3 + 24 * (soc.toInt().coerceIn(0, 100) / 100f), mid + 5)
                canvas.drawRoundRect(tmp, 1.5f, 1.5f, fill)
                x += 43f
                text.typeface = numeral
                text.textSize = 30f
                text.color = bone
                val value = soc.toInt().toString()
                canvas.drawText(value, x, mid + 11f, text)
                x += text.measureText(value) + 3f
                text.typeface = caption
                text.textSize = 17f
                text.color = ash
                canvas.drawText("%", x, mid + 11f, text)
                x += text.measureText("%") + 14f
            }
            var right = x0 + w - 62f
            if (!stale) {
                if (bool("trunk") && model["state"] == "collapsed") {
                    right -= BOOT
                    tmp.set(right + 6f, mid - 28f, right + 62f, mid + 28f)
                    fill.color = alpha(bone, 0.09f)
                    canvas.drawRoundRect(tmp, 28f, 28f, fill)
                    stroke.strokeWidth = 1f
                    stroke.color = hair
                    canvas.drawRoundRect(tmp, 28f, 28f, stroke)
                    boot(canvas, tmp.centerX(), mid, bone)
                    hits.add(RectF(right, y0, right + BOOT, y0 + ROW) to "trunk")
                }
                // Whatever does not fit after the battery is left out: the
                // alert dot first, since it is the one that asks for a look.
                if (bool("dot") && right - 24f >= x) {
                    right -= 24f
                    fill.color = warning
                    canvas.drawCircle(right + 12f, mid, 6f, fill)
                }
                if (bool("highBeam") && right - 40f >= x) {
                    right -= 40f
                    beam(canvas, right + 20f, mid, int("beam"))
                }
                if (bool("trunkOpen") && right - 40f >= x) {
                    right -= 40f
                    boot(canvas, right + 20f, mid, warning)
                }
            }
            val note = if (stale) "OpenDash not responding" else str("note")
            if (note.isNotEmpty()) {
                val strong = stale || bool("noteStrong")
                text.typeface = if (strong) label else caption
                text.textSize = if (strong) 20f else 17f
                text.color = if (stale) warning else int("noteColor")
                // All of it or none: "115 km" cut to "11…" says the wrong
                // thing (seen in the Chrome preview). The open
                // panel has the room.
                if (text.measureText(note) <= right - x - 6f) canvas.drawText(note, x, mid + 7f, text)
            }
        }

        private fun drawSub(canvas: Canvas, sub: Map<*, *>, x0: Float, y0: Float, bone: Int, hair: Int) {
            val mid = y0 + SUB / 2
            val from = x0 + 26f
            val end = x0 + w - 26f
            val message = sub["text"] as? String ?: ""
            val bar = (sub["bar"] as? Number)?.toFloat()
            text.typeface = label
            text.textSize = 19f
            text.color = bone
            if (bar == null) {
                canvas.drawText(TextUtils.ellipsize(message, text, end - from, TextUtils.TruncateAt.END).toString(), from, mid + 6.5f, text)
                return
            }
            canvas.drawText(message, from, mid + 6.5f, text)
            // A countdown is not a share of anything: no "0%" beside "Locking".
            val percent = if (sub["percent"] == false) "" else "${(bar * 100).toInt()}%"
            val left = from + text.measureText(message) + 18f
            text.typeface = numeral
            val right = if (percent.isEmpty()) end else end - text.measureText(percent) - 14f
            fill.color = hair
            tmp.set(left, mid - 3, right, mid + 3)
            canvas.drawRoundRect(tmp, 3f, 3f, fill)
            fill.color = bone
            tmp.set(left, mid - 3, left + (right - left) * bar.coerceIn(0f, 1f), mid + 3)
            canvas.drawRoundRect(tmp, 3f, 3f, fill)
            if (percent.isNotEmpty()) canvas.drawText(percent, end - text.measureText(percent), mid + 6.5f, text)
        }

        private fun drawAttention(canvas: Canvas, a: Map<*, *>, x0: Float, y0: Float, bone: Int, ash: Int, hair: Int) {
            val rowH = h - ROW
            val mid = y0 + (if (a["action"] != null) H_ACTION else H_ATTENTION) / 2
            hits.add(RectF(x0, y0, x0 + w, y0 + rowH) to "att")
            var right = x0 + w - 12f
            for (key in listOf("action", "action2")) {
                val caption = a[key] as? String ?: continue
                text.typeface = label
                text.textSize = 24f
                val bw = text.measureText(caption) + 60f
                tmp.set(right - bw, mid - 48, right, mid + 48)
                val primary = key == "action"
                fill.color = if (primary) bone else alpha(bone, 0.09f)
                canvas.drawRoundRect(tmp, 28f, 28f, fill)
                if (!primary) {
                    stroke.strokeWidth = 1f
                    stroke.color = hair
                    canvas.drawRoundRect(tmp, 28f, 28f, stroke)
                }
                text.color = if (primary) (if (bool("light")) Color.WHITE else Color.rgb(11, 13, 17)) else bone
                canvas.drawText(caption, tmp.centerX() - text.measureText(caption) / 2, mid + 8f, text)
                hits.add(RectF(tmp) to key)
                right -= bw + 12f
            }

            val priority = a["priority"]
            val disc = if (priority == "critical") int("critical") else if (priority == "warning") int("warning") else ash
            fill.color = disc
            canvas.drawCircle(x0 + 52f, mid, 26f, fill)
            val badge = a["badge"] as? String ?: ""
            if (badge.isNotEmpty()) {
                text.typeface = numeral
                text.textSize = 30f
                text.color = if (priority == "critical") Color.WHITE else Color.rgb(20, 22, 26)
                canvas.drawText(badge, x0 + 52f - text.measureText(badge) / 2, mid + 11f, text)
            }

            val textLeft = x0 + 96f
            val room = right - textLeft - 8f
            val body = a["body"] as? String ?: ""
            text.typeface = label
            text.textSize = 28f
            text.color = bone
            val title = TextUtils.ellipsize(a["title"] as? String ?: "", text, room, TextUtils.TruncateAt.END).toString()
            canvas.drawText(title, textLeft, if (body.isEmpty()) mid + 10f else mid - 2f, text)
            if (body.isNotEmpty()) {
                text.typeface = caption
                text.textSize = 19f
                text.color = ash
                canvas.drawText(TextUtils.ellipsize(body, text, room, TextUtils.TruncateAt.END).toString(), textLeft, mid + 24f, text)
            }
        }

        private fun drawExpanded(canvas: Canvas, x0: Float, y0: Float, bone: Int, ash: Int, hair: Int) {
            val controls = (model["controls"] as? List<*>).orEmpty().filterIsInstance<Map<*, *>>()
            val gap = 12f
            val inner = w - 36f
            if (controls.isNotEmpty()) {
                val cw = (inner - gap * (controls.size - 1)) / controls.size
                controls.forEachIndexed { i, c ->
                    val id = c["id"] as? String ?: return@forEachIndexed
                    val on = c["on"] == true
                    val enabled = c["enabled"] != false
                    val a = if (enabled) 1f else 0.38f
                    tmp.set(x0 + 18f + i * (cw + gap), y0 + 14f, x0 + 18f + i * (cw + gap) + cw, y0 + 118f)
                    val active = if (id == "hazard") int("warning") else int("beam")
                    fill.color = if (on) active else alpha(bone, 0.09f * a)
                    canvas.drawRoundRect(tmp, 20f, 20f, fill)
                    if (!on) {
                        stroke.strokeWidth = 1f
                        stroke.color = hair
                        canvas.drawRoundRect(tmp, 20f, 20f, stroke)
                    }
                    val ink = if (on) Color.rgb(11, 13, 17) else alpha(bone, a)
                    when (id) {
                        "hazard" -> hazard(canvas, tmp.centerX(), tmp.top + 38f, ink)
                        "highBeam" -> beam(canvas, tmp.centerX(), tmp.top + 38f, ink)
                        else -> boot(canvas, tmp.centerX(), tmp.top + 38f, ink)
                    }
                    val caption = c["label"] as? String ?: ""
                    text.typeface = label
                    text.textSize = 18f
                    text.color = ink
                    canvas.drawText(caption, tmp.centerX() - text.measureText(caption) / 2, tmp.top + 84f, text)
                    if (enabled) hits.add(RectF(tmp) to id)
                }
            }

            val apps = (model["apps"] as? List<*>).orEmpty().filterIsInstance<Map<*, *>>()
            val weights = 1.3f + apps.size
            val unit = (inner - gap * apps.size) / weights
            var x = x0 + 18f
            val top = y0 + 130f
            tmp.set(x, top, x + unit * 1.3f, top + 72f)
            fill.color = bone
            canvas.drawRoundRect(tmp, 20f, 20f, fill)
            text.typeface = label
            text.textSize = 22f
            text.color = if (bool("light")) Color.WHITE else Color.rgb(11, 13, 17)
            backLabel(canvas, tmp.centerX(), tmp.centerY(), 22f, text.color)
            hits.add(RectF(tmp) to "back")
            x += unit * 1.3f + gap
            for (app in apps) {
                tmp.set(x, top, x + unit, top + 72f)
                fill.color = alpha(bone, 0.09f)
                canvas.drawRoundRect(tmp, 20f, 20f, fill)
                stroke.strokeWidth = 1f
                stroke.color = hair
                canvas.drawRoundRect(tmp, 20f, 20f, stroke)
                text.color = bone
                val name = TextUtils.ellipsize(app["label"] as? String ?: "", text, unit - 16f, TextUtils.TruncateAt.END).toString()
                canvas.drawText(name, tmp.centerX() - text.measureText(name) / 2, tmp.centerY() + 8f, text)
                hits.add(RectF(tmp) to "app:${app["id"]}")
                x += unit + gap
            }
        }

        private fun arrow(canvas: Canvas, cx: Float, cy: Float, left: Boolean, color: Int) {
            val d = if (left) -1f else 1f
            path.rewind()
            path.moveTo(cx + 13f * d, cy)
            path.lineTo(cx + 1f * d, cy - 11f)
            path.lineTo(cx + 1f * d, cy - 4f)
            path.lineTo(cx - 13f * d, cy - 4f)
            path.lineTo(cx - 13f * d, cy + 4f)
            path.lineTo(cx + 1f * d, cy + 4f)
            path.lineTo(cx + 1f * d, cy + 11f)
            path.close()
            fill.color = color
            canvas.drawPath(path, fill)
        }

        private fun beam(canvas: Canvas, cx: Float, cy: Float, color: Int) {
            stroke.color = color
            stroke.strokeWidth = 2.5f
            stroke.strokeCap = Paint.Cap.ROUND
            path.rewind()
            path.moveTo(cx + 1f, cy - 10f)
            path.cubicTo(cx + 14f, cy - 10f, cx + 14f, cy + 10f, cx + 1f, cy + 10f)
            path.close()
            canvas.drawPath(path, stroke)
            for (dy in listOf(-7f, 0f, 7f)) canvas.drawLine(cx - 13f, cy + dy, cx - 5f, cy + dy, stroke)
            stroke.strokeCap = Paint.Cap.BUTT
        }

        private fun hazard(canvas: Canvas, cx: Float, cy: Float, color: Int) {
            stroke.color = color
            stroke.strokeWidth = 2.5f
            stroke.strokeJoin = Paint.Join.ROUND
            path.rewind()
            path.moveTo(cx, cy - 13f)
            path.lineTo(cx + 15f, cy + 12f)
            path.lineTo(cx - 15f, cy + 12f)
            path.close()
            path.moveTo(cx, cy - 3f)
            path.lineTo(cx + 6.5f, cy + 7.5f)
            path.lineTo(cx - 6.5f, cy + 7.5f)
            path.close()
            canvas.drawPath(path, stroke)
        }

        /// "← OpenDash", centred on [cx]: the toolbar's back arrow (a shaft
        /// and a head, round ends) with the name beside it, so leaving
        /// another app looks like going back does inside OpenDash.
        private fun backLabel(canvas: Canvas, cx: Float, cy: Float, size: Float, color: Int) {
            val name = "OpenDash"
            text.typeface = label
            text.textSize = size
            text.color = color
            val arrow = size * 0.8f
            val gap = size * 0.45f
            val left = cx - (arrow + gap + text.measureText(name)) / 2
            stroke.color = color
            stroke.strokeWidth = size * 0.11f
            stroke.strokeCap = Paint.Cap.ROUND
            stroke.strokeJoin = Paint.Join.ROUND
            path.rewind()
            path.moveTo(left + arrow, cy)
            path.lineTo(left, cy)
            path.moveTo(left + arrow * 0.45f, cy - arrow * 0.45f)
            path.lineTo(left, cy)
            path.lineTo(left + arrow * 0.45f, cy + arrow * 0.45f)
            canvas.drawPath(path, stroke)
            stroke.strokeCap = Paint.Cap.BUTT
            canvas.drawText(name, left + arrow + gap, cy + size * 0.35f, text)
        }

        /// The dashboard's trunk icon (`_TrunkPainter` in status_icons.dart):
        /// a box with its lid lifted.
        private fun boot(canvas: Canvas, cx: Float, cy: Float, color: Int) {
            stroke.color = color
            stroke.strokeWidth = 2.4f
            stroke.strokeJoin = Paint.Join.ROUND
            stroke.strokeCap = Paint.Cap.ROUND
            val k = 1.1f
            // Not [tmp]: the caller is still using it for the button.
            icon.set(cx - 14f * k, cy, cx + 14f * k, cy + 9.9f * k)
            canvas.drawRoundRect(icon, 3f, 3f, stroke)
            canvas.drawLine(cx - 11.4f * k, cy, cx + 6.6f * k, cy - 10f * k, stroke)
            stroke.strokeCap = Paint.Cap.BUTT
        }

        @SuppressLint("ClickableViewAccessibility")
        override fun onTouchEvent(e: MotionEvent): Boolean {
            when (e.actionMasked) {
                MotionEvent.ACTION_OUTSIDE -> {
                    BackgroundTouch.noteTouch()
                    send("outside", emptyMap())
                }
                MotionEvent.ACTION_DOWN -> {
                    BackgroundTouch.noteTouch()
                    // Dart counts down to the vehicle's idle lock from the
                    // last touch it knows of; a drag is one too.
                    send("touch", emptyMap())
                    downX = e.rawX
                    downY = e.rawY
                    startX = params.x
                    startY = params.y
                    dragging = false
                    travelled = 0f
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = e.rawX - downX
                    val dy = e.rawY - downY
                    travelled = max(travelled, max(abs(dx), abs(dy)))
                    val movable = !bool("moving") && !stale
                    if (!dragging && movable && travelled > 2 * slop) dragging = true
                    if (dragging) {
                        params.x = startX + dx.toInt()
                        params.y = startY + dy.toInt()
                        try {
                            wm.updateViewLayout(this, params)
                        } catch (_: Exception) {
                        }
                    }
                }
                MotionEvent.ACTION_UP -> if (dragging) {
                    val cx = params.x + params.width / 2
                    val cy = params.y + params.height / 2
                    snap = (if (cy > screen.y / 2) "b" else "t") + (if (cx < screen.x / 3) "l" else if (cx > screen.x * 2 / 3) "r" else "c")
                    prefs.edit().putString("snap_${model["app"]}", snap).apply()
                    relayout(max(w, destW), max(h, destH))
                    invalidate()
                    Analytics.log("island", "drag", mapOf("snap" to snap))
                } else if (travelled <= (if (bool("moving")) 3 else 2) * slop) {
                    // A finger that travelled is never a tap: on the scooter,
                    // drags that did not start opened the panel and the boot.
                    // On the move the hand shakes, so a little more is a tap.
                    val x = e.x
                    val y = e.y
                    // Buttons are added after the row they sit in.
                    hits.lastOrNull { it.first.contains(x, y) }?.let { tapped(it.second) }
                }
                MotionEvent.ACTION_CANCEL -> if (dragging) relayout(w, h)
            }
            return true
        }
    }
}

/// Keeps the process out of the low-memory killer's reach while another
/// app is in front: a visible overlay does that by itself, but Android
/// hides overlays over its installer and permission screens, and the
/// island hides itself too. Does no work.
class IslandService : Service() {
    companion object {
        private const val CHANNEL_ID = "island"
        private const val STOP = "stop"

        fun start(context: Context) {
            try {
                context.startForegroundService(Intent(context, IslandService::class.java))
            } catch (e: Exception) {
                Analytics.log("island", "service_error", mapOf("error" to e.toString()))
            }
        }

        /// Through the service itself, not `stopService`: stopping one that
        /// was asked to start but has not yet called `startForeground`
        /// crashes the process on Android 8 to 11.
        fun stop(context: Context) {
            try {
                context.startForegroundService(Intent(context, IslandService::class.java).setAction(STOP))
            } catch (e: Exception) {
                Analytics.log("island", "service_error", mapOf("error" to e.toString()))
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL_ID, "Over other apps", NotificationManager.IMPORTANCE_MIN))
        startForeground(
            1,
            Notification.Builder(this, CHANNEL_ID)
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle("OpenDash is running over another app")
                .build(),
        )
        if (intent?.action == STOP) {
            @Suppress("DEPRECATION") stopForeground(true)
            stopSelf()
        }
        return START_NOT_STICKY
    }
}
