package com.openviewai.synhub

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.audiofx.Visualizer
import android.os.Build
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.sqrt

/**
 * 播放律动的**真频谱**桥：`android.media.audiofx.Visualizer` → Dart（第 274 轮）。
 *
 * ## 为什么现在才做
 *
 * 第 261 轮落地律动动效时，`lib/src/features/media/audio_visualizer.dart` 的文件头
 * 明确写着"真频谱这条路被权限挡住 ⇒ 只做**推导**动效"。当时的结论对**那时**成立：
 * `Visualizer` 的官方文档逐字要求 `android.permission.RECORD_AUDIO`
 * （"the use of the visualizer requires the permission android.permission.RECORD_AUDIO"）。
 *
 * 第 274 轮用户再次报「没有播放视觉特效」并要求**优先真频谱**。事实核查：
 *   * 本 App 的 `AndroidManifest.xml` **本来就声明** `RECORD_AUDIO`
 *     （聊天语音消息要用），**不需要新增任何权限声明**；
 *   * 真机 Honor LGE-AN10 上 `dumpsys package` 里它是
 *     `android.permission.RECORD_AUDIO: granted=true`。
 *
 * 所以真频谱**不是**做不到。这里的取舍（照任务书）：
 *   * **只在权限已经授予时**建 `Visualizer`；没授予就**直接回 `ok=false`**，
 *     **绝不在这条路径上弹权限框**（音频站页面以前从不问麦克风，不能因为
 *     视觉特效突然弹窗——见 [probe] 的 returns）；
 *   * 任何一步失败（权限/会话 id 非法/平台不支持）→ `ok=false`，
 *     Dart 侧**回落到既有的推导动效**（已真机验证可用），不崩、不空屏。
 *
 * ## 与既有播放器的关系（AGENTS §2.0.8 ④：不新开第二条播放路径）
 *
 * 本桥**不碰播放**：它只吃 Dart 侧转过来的 **audio session id**
 * （`just_audio` 的 `androidAudioSessionIdStream`，Android 上就是 ExoPlayer 的
 * 会话 id），**不建自己的播放器、不碰 `_sid`、不取流**。
 *
 * 通道（契约由 `lib/src/features/media/audio_visualizer_source.dart` 固定）：
 *  * MethodChannel `synhub/audio_visualizer`
 *      - `probe`  → `{available:Bool, hasPermission:Bool, reason:String}`
 *      - `attach` → 入参 `{sessionId:Int, bars:Int}`，回 `{ok:Bool, reason:String}`
 *      - `detach` → Bool
 *  * EventChannel `synhub/audio_visualizer/events` → `List<Double>`（长度 = bars，
 *      每项 0..1）。**只有 attach 成功且被 listen 时才有事件**。
 *
 * ## 诚实边界（别在报告里假装）
 *   * 这是**真频谱**（FFT 幅值），但它采集的是**播放输出的混音**，不是"文件的
 *     原始采样"——有音效/EQ 时看到的是处理后的结果，这与所有平台的 Visualizer
 *     语义一致；
 *   * 采集率受 `getMaxCaptureRate()` 限制（真机通常 20 Hz），所以 Dart 侧仍会
 *     用它做**插值补帧**，不是 60 fps 的独立采样；
 *   * `bars` 超过 FFT 有效 bin 数时高位 band 会退化成同一个 bin（低频更细、
 *     高频更粗，这是 log 分段的正常结果，不是 bug）。
 */
object AudioVisualizerBridge {
    private const val TAG = "AudioVisualizerBridge"
    private const val CHANNEL = "synhub/audio_visualizer"
    private const val EVENTS = "synhub/audio_visualizer/events"

    /** 最少多少毫秒才推一帧（约 25 Hz；真机上限一般 20 Hz，这只是兜底）。 */
    private const val MIN_EMIT_INTERVAL_MS = 40L

    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var appContext: Context? = null

    private var visualizer: Visualizer? = null
    private var sink: EventChannel.EventSink? = null
    private var bars = 0
    private var smoothed: FloatArray = FloatArray(0)
    private var peak = 1e-3f
    private var lastEmitMs = 0L

    fun attach(context: Context, engine: FlutterEngine) {
        appContext = context.applicationContext
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "probe" -> result.success(probe())
                "attach" -> {
                    val sessionId = call.argument<Int>("sessionId") ?: -1
                    val barCount = call.argument<Int>("bars") ?: 28
                    result.success(attachSpectrum(sessionId, barCount))
                }
                "detach" -> {
                    release()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        val ec = EventChannel(engine.dartExecutor.binaryMessenger, EVENTS)
        eventChannel = ec
        ec.setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    sink = events
                }

                override fun onCancel(arguments: Any?) {
                    sink = null
                }
            },
        )
    }

    fun detach() {
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        eventChannel?.setStreamHandler(null)
        eventChannel = null
        release()
        appContext = null
    }

    /**
     * 本机能不能出真频谱。**只读权限状态，绝不申请**。
     *
     * `reason` 是给 Dart 侧打日志/做归因的**可查询原因串**（不是给用户看的文案）：
     * `ok` / `permission-not-granted` / `no-context`。
     */
    private fun probe(): Map<String, Any> {
        val ctx = appContext
        if (ctx == null) {
            return mapOf("available" to false, "hasPermission" to false, "reason" to "no-context")
        }
        val granted = hasRecordAudio(ctx)
        return mapOf(
            "available" to granted,
            "hasPermission" to granted,
            "reason" to if (granted) "ok" else "permission-not-granted",
        )
    }

    private fun hasRecordAudio(ctx: Context): Boolean {
        val ok = ctx.checkSelfPermission(Manifest.permission.RECORD_AUDIO)
        return ok == PackageManager.PERMISSION_GRANTED
    }

    private fun attachSpectrum(sessionId: Int, barCount: Int): Map<String, Any> {
        val ctx = appContext ?: return fail("no-context")
        if (sessionId <= 0) return fail("no-session-id")
        if (barCount <= 0) return fail("bad-bars")
        if (!hasRecordAudio(ctx)) return fail("permission-not-granted")
        release()
        return try {
            val vis = Visualizer(sessionId)
            val range = Visualizer.getCaptureSizeRange()
            // captureSize 必须是 2 的幂，且落在 [range[0], range[1]]
            val want = Integer.highestOneBit(max(64, barCount * 4))
            val size = want.coerceIn(range[0], range[1])
            vis.captureSize = size
            bars = barCount
            smoothed = FloatArray(barCount)
            peak = 1e-3f
            lastEmitMs = 0L
            // fft = true → 真频谱；waveform = false（不需要时域波形）
            vis.setDataCaptureListener(
                object : Visualizer.OnDataCaptureListener {
                    override fun onWaveFormDataCapture(
                        v: Visualizer?,
                        waveform: ByteArray?,
                        samplingRate: Int,
                    ) = Unit

                    override fun onFftDataCapture(
                        v: Visualizer?,
                        fft: ByteArray?,
                        samplingRate: Int,
                    ) {
                        if (fft == null) return
                        val out = onFft(fft)
                        val s = sink ?: return
                        val now = System.currentTimeMillis()
                        if (now - lastEmitMs < MIN_EMIT_INTERVAL_MS) return
                        lastEmitMs = now
                        try {
                            s.success(out.toList())
                        } catch (e: Throwable) {
                            Log.w(TAG, "emit failed", e)
                        }
                    }
                },
                Visualizer.getMaxCaptureRate(),
                false,
                true,
            )
            vis.enabled = true
            visualizer = vis
            Log.i(TAG, "真频谱已启用：session=$sessionId bars=$barCount captureSize=$size " +
                "rate=${Visualizer.getMaxCaptureRate()}mHz sdk=${Build.VERSION.SDK_INT}")
            mapOf("ok" to true, "reason" to "ok", "captureSize" to size)
        } catch (e: Throwable) {
            Log.w(TAG, "attach failed: ${e.javaClass.simpleName}: ${e.message}")
            release()
            fail("attach-failed:${e.javaClass.simpleName}")
        }
    }

    /**
     * FFT 字节对（re, im）→ log 分段的 `bars` 个 0..1 电平。
     *
     * 归一化用**带衰减的运行峰值**：安静段不会突然被拉满，爆音也不会把整幅压扁。
     */
    private fun onFft(fft: ByteArray): FloatArray {
        val bins = fft.size / 2
        val n = bars
        val out = FloatArray(n)
        if (bins <= 1 || n <= 0) return out
        // log 分段：低频给更细的分辨率（人耳/视觉都更吃低频）
        val edges = IntArray(n + 1)
        for (i in 0..n) {
            val frac = i.toDouble() / n
            edges[i] = (Math.pow(bins.toDouble(), frac)).toInt().coerceIn(0, bins - 1)
        }
        for (i in 0 until n) {
            var lo = edges[i]
            val hi = max(edges[i + 1], lo + 1).coerceAtMost(bins)
            var acc = 0.0
            var count = 0
            while (lo < hi) {
                val re = fft[lo * 2].toInt()
                val im = fft[lo * 2 + 1].toInt()
                acc += sqrt((re * re + im * im).toDouble())
                count++
                lo++
            }
            val mag = if (count == 0) 0.0 else acc / count
            // 对数压缩：线性幅值在视觉上永远是"左边一根冲天柱"
            val v = (ln(1.0 + mag) / ln(1.0 + 128.0)).toFloat()
            out[i] = v
        }
        for (i in 0 until n) {
            smoothed[i] = max(out[i], smoothed[i] * 0.72f)
        }
        var m = 0f
        for (i in 0 until n) m = max(m, smoothed[i])
        peak = max(peak * 0.985f, m)
        if (peak < 1e-3f) peak = 1e-3f
        for (i in 0 until n) {
            out[i] = (smoothed[i] / peak).coerceIn(0f, 1f)
        }
        return out
    }

    private fun fail(reason: String): Map<String, Any> =
        mapOf("ok" to false, "reason" to reason)

    private fun release() {
        try {
            visualizer?.enabled = false
        } catch (e: Throwable) {
            Log.w(TAG, "disable failed", e)
        }
        try {
            visualizer?.release()
        } catch (e: Throwable) {
            Log.w(TAG, "release failed", e)
        }
        visualizer = null
        bars = 0
        smoothed = FloatArray(0)
    }
}
