package com.openviewai.synhub

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlin.math.abs

/**
 * 折叠姿态（铰链角）桥：`SensorManager` → Dart（第 294 轮）。
 *
 * ## 为什么需要它（真机取证，不是推测）
 *
 * 本仓的折痕避让（`lib/src/core/ui/adaptive_layout.dart` 的
 * `FoldAvoidingLayout` / `AdaptiveContainer` 路径）**唯一**的信号源是
 * `dart:ui` 的 `FlutterView.displayFeatures`。真机 **HUAWEI Mate X2
 * (TET-AN00, UDU0221309003011)** 上逐位实测（第 294 轮）：
 *
 *   * `MediaQuery.displayFeatures` **恒空**（`nFeat=0`，竖/横两个朝向都空）
 *     ⇒ 现有避让在这台机器上**空转**：半折时内容照样压在折痕上；
 *   * 但**传感器真值可读**（`dumpsys sensorservice` 与实测录制）：
 *       - `android.sensor.hinge_angle(36)`（**标准**，API 30+）；
 *       - `android.sensor.posture(65573)`（华为私有 type = 0x10025，
 *         **系统自己已订阅**，`connections=2`，实测约 50 Hz 出数）；
 *   * 实测角度（第 293 轮 `/tmp/r293_fold/posture.log`，132 行）：
 *       摊平 **179.34°** / 手摆 90° 档 = **86.80°** / 手摆 45° 档 = **42.20°** /
 *       完全合上 **1.2°** / 再摊平 **179.88°**。
 *
 * 两条**实测得出**的判据（Dart 侧 `fold_posture.dart` 用它做三态映射）：
 *   * `posture` 事件第 **7** 个字段（下标 6）就是铰链角度，第 8 个字段
 *     （下标 7）是离散姿态码（实测 0.51 / 0.26 / 0.00）；
 *   * 姿态码**有滞后**（角度 87° 时它仍是 0.51）⇒ **判据只用角度**，
 *     姿态码原样上报仅作兜底/诊断，**不参与**三态判定。
 *
 * ## 权限：**零**
 *
 * `hinge_angle` / `posture` 都是**普通传感器**（`dumpsys sensorservice`
 * 里 `perm: n/a`），**不需要任何运行时权限，也不要在 Manifest 里加声明**。
 * 本桥是**只读**：不改系统状态、不写文件、不发网络。
 *
 * ## 通道契约（Dart 侧固定在 `lib/src/core/ui/fold_posture.dart`）
 *
 *  * MethodChannel `synhub/fold_posture`
 *      - `read`  → `{angleDegrees: Double?, postureCode: Double?,
 *                    source: 'hinge_angle'|'posture'|'unknown', subscribed: Bool}`
 *        **零延迟**返回"最后一次收到的样本"；没有任何样本时
 *        `angleDegrees = null` 且 `source = 'unknown'` —— **绝不编一个角度**
 *        （AGENTS §2.0.6 纪律：拿不到就是 `unknown`）。
 *      - `probe` → 传感器存在性/类型号/API 级别的**诊断**读数（只读）。
 *  * EventChannel `synhub/fold_posture/events` → 同上结构体的流。
 *      **只有 `onListen` 之后、且 Activity 处于 `onResume` 时才有事件**。
 *
 * ## 生命周期（本桥最容易出错的地方）
 *
 * `configureFlutterEngine` 里**不许**常驻注册 —— 传感器是耗电资源，
 * 页面不在前台就不该采。所以本桥把注册条件写成"**两个都满足**"：
 *   ① EventChannel 有监听者（`sink != null`）；
 *   ② Activity 已 `onResume`（`resumed == true`）。
 * 任一条不成立就**立即注销**（`onCancel` / `onPause` / `onDestroy`），
 * 并**保留最后一次已知样本**（`on-change` 传感器的 HAL 在重新注册时会立刻
 * 补一帧当前值，所以 `onResume` 会自我校正；这样回前台时布局不会先跳一下）。
 * 而**从未收到过样本**（首次启动 / 两条传感器都没有 / 桥缺失）时
 * `angleDegrees` 恒为 `null` ⇒ Dart 侧看到的是 `unknown` ⇒ 布局 **fail-open**
 * 回到改造前的行为（不因为"读不到姿态"而改变布局）。
 *
 * ## 回落逻辑（标准优先，华为私有兜底）
 *
 * 1. API 30+ 且有 `Sensor.TYPE_HINGE_ANGLE`（= **36**）⇒ 先注册**标准**那一路；
 * 2. 标准那一路若 [HINGE_SILENT_FALLBACK_MS] 内**一个事件都没有**
 *    （实测该传感器在当前系统上无人订阅、注册后才出数，所以这条兜底是
 *    真实存在的路径）⇒ **再挂上**华为 `posture(65573)` 作为第二路；
 * 3. 标准那一路一旦出数 ⇒ **立刻撤掉**第二路（`unregisterListener(listener,
 *    sensor)` 只摘这一个，不动标准那一路），`source` 从此恒为 `hinge_angle`。
 *
 * ⇒ 真机日志里应当能看到 `hinge_angle silent … → fallback to posture`。
 */
object FoldPostureBridge {
    private const val TAG = "FoldPostureBridge"
    private const val CHANNEL = "synhub/fold_posture"
    private const val EVENTS = "synhub/fold_posture/events"

    /**
     * 华为私有姿态传感器 `android.sensor.posture` 的类型号。
     *
     * 0x10025 = 65573。它**不在** 公开的 `Sensor.TYPE_*` 常量里
     * （`Sensor.TYPE_ALL` 也只是个 `-1` 的哨兵值），所以这里只能写死数字；
     * 依据是 `dumpsys sensorservice` 的原文
     * `type: android.sensor.posture(65573)`（第 293/294 轮真机读数）。
     */
    private const val TYPE_HUAWEI_POSTURE = 65573

    /** 华为姿势事件里**铰链角度**的下标（实测第 7 个字段）。 */
    private const val POSTURE_INDEX_ANGLE = 6

    /** 华为姿势事件里**离散姿态码**的下标（实测第 8 个字段；有滞后，仅诊断）。 */
    private const val POSTURE_INDEX_CODE = 7

    /** 标准铰链角注册后多久没事件就挂第二路（回落的判据）。 */
    private const val HINGE_SILENT_FALLBACK_MS = 1500L

    /** 事件节流：最多 10 Hz（50 Hz 全量推给 Dart 是浪费，且会拖慢 UI 帧）。 */
    private const val MIN_EMIT_INTERVAL_MS = 100L

    /** 角度变化超过这么多度就**不等节流**立刻发。 */
    private const val EMIT_ON_DELTA_DEGREES = 2.0

    /** `Sensor.TYPE_HINGE_ANGLE`（= 36）在 API 30+ 才存在；低于则 `-1`。 */
    private val hingeType: Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) Sensor.TYPE_HINGE_ANGLE else -1

    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var appContext: Context? = null
    private var sink: EventChannel.EventSink? = null

    private var resumed = false
    private var subscribed = false

    private var hingeSensor: Sensor? = null
    private var postureSensor: Sensor? = null

    /** 标准那一路是否已经真的出过数（出了就不再需要兜底）。 */
    private var hingeHasEvent = false

    /** 华为兜底那一路是否已注册（要单独记，注销时必须按 sensor 摘）。 */
    private var postureRegistered = false

    private var angleDegrees: Double? = null
    private var postureCode: Double? = null
    private var source: String = "unknown"

    private var lastEmitAtMs = 0L
    private var lastSentAngle: Double? = null

    private val main = Handler(Looper.getMainLooper())
    private var fallbackTask: Runnable? = null

    // ------------------------------------------------------------------ 采集

    private val listener = object : SensorEventListener {
        override fun onSensorChanged(event: SensorEvent) {
            val values = event.values ?: return
            when (event.sensor.type) {
                hingeType -> {
                    if (values.isEmpty()) return
                    val v = values[0].toDouble()
                    if (!v.isFinite()) return
                    angleDegrees = v
                    source = "hinge_angle"
                    hingeHasEvent = true
                    // 标准那一路活了 ⇒ 撤掉华为私有兜底（只摘那一个注册）
                    stopPostureFallback()
                }
                TYPE_HUAWEI_POSTURE -> {
                    // ★ 真机实测（TET-AN00 / Android 12 / API 31）：**普通 App 拿到的
                    //   payload 只有 7 个值（下标 0..6）** —— 第 7 位（离散姿态码）
                    //   只有系统订阅才看得到（`dumpsys sensorservice` 的
                    //   "last 10 events" 是 16 个值）。所以这里**只要求"够读到下标 6
                    //   的角度"**；姿态码有就读、没有就是 `null`（"不知道" ≠ 0，§2.0.6）。
                    //   ⚠️ 若拿 `values.size <= POSTURE_INDEX_CODE` 当守卫，本机
                    //   **一帧都读不到**（第 294 轮真机踩到：注册成功、零事件、logcat 空白）。
                    if (values.size <= POSTURE_INDEX_ANGLE) return
                    val v = values[POSTURE_INDEX_ANGLE].toDouble()
                    if (!v.isFinite()) return
                    angleDegrees = v
                    postureCode = if (values.size > POSTURE_INDEX_CODE) {
                        values[POSTURE_INDEX_CODE].toDouble()
                    } else {
                        null
                    }
                    // ★ 单一语义：只要有标准读数就以标准为准；姿态码只上报不判定。
                    if (!hingeHasEvent) source = "posture"
                }
                else -> return
            }
            emit()
        }

        override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit
    }

    private fun sensorManager(): SensorManager? =
        appContext?.getSystemService(Context.SENSOR_SERVICE) as? SensorManager

    private fun register() {
        if (subscribed) return
        val sm = sensorManager()
        if (sm == null) {
            resetSample()
            return
        }
        hingeSensor = if (hingeType > 0) sm.getDefaultSensor(hingeType) else null
        postureSensor = try {
            sm.getDefaultSensor(TYPE_HUAWEI_POSTURE)
        } catch (t: Throwable) {
            Log.w(TAG, "getDefaultSensor(posture) failed: ${t.javaClass.simpleName}")
            null
        }

        var ok = false
        val h = hingeSensor
        if (h != null) {
            ok = sm.registerListener(listener, h, SensorManager.SENSOR_DELAY_UI)
            if (!ok) Log.w(TAG, "registerListener(hinge_angle=$hingeType) returned false")
        }
        if (ok) {
            subscribed = true
            // 标准那一路存在时给华为兜底留一个"沉默窗口"
            if (postureSensor != null) schedulePostureFallback(sm)
            Log.i(
                TAG,
                "registered hinge_angle(type=$hingeType) api=${Build.VERSION.SDK_INT}",
            )
        } else if (registerPostureFallback(sm)) {
            subscribed = true
            Log.i(TAG, "registered posture(type=$TYPE_HUAWEI_POSTURE) only")
        } else {
            // 两条路都没有 ⇒ 如实 unknown，绝不编角度（AGENTS §2.0.6）
            subscribed = false
            resetSample()
            Log.w(
                TAG,
                "no fold sensor: hasHinge=${hingeSensor != null} hasPosture=${postureSensor != null}",
            )
            sink?.success(snapshot())
        }
    }

    private fun schedulePostureFallback(sm: SensorManager) {
        cancelFallbackTask()
        val task = Runnable {
            fallbackTask = null
            if (subscribed && !hingeHasEvent && registerPostureFallback(sm)) {
                Log.i(
                    TAG,
                    "hinge_angle silent ${HINGE_SILENT_FALLBACK_MS}ms → fallback to posture($TYPE_HUAWEI_POSTURE)",
                )
            }
        }
        fallbackTask = task
        main.postDelayed(task, HINGE_SILENT_FALLBACK_MS)
    }

    private fun registerPostureFallback(sm: SensorManager): Boolean {
        if (postureRegistered) return true
        val p = postureSensor ?: return false
        val ok = sm.registerListener(listener, p, SensorManager.SENSOR_DELAY_UI)
        postureRegistered = ok
        return ok
    }

    /** 只摘华为兜底那一路 —— **不能**用 `unregisterListener(listener)`（那会连标准一起摘）。 */
    private fun stopPostureFallback() {
        cancelFallbackTask()
        if (!postureRegistered) return
        postureRegistered = false
        postureSensor?.let { sensorManager()?.unregisterListener(listener, it) }
    }

    private fun cancelFallbackTask() {
        fallbackTask?.let { main.removeCallbacks(it) }
        fallbackTask = null
    }

    private fun unregister(reason: String) {
        cancelFallbackTask()
        val was = subscribed
        subscribed = false
        if (was) {
            sensorManager()?.unregisterListener(listener)
            Log.i(TAG, "unregistered ($reason)")
        }
        postureRegistered = false
        hingeHasEvent = false
        lastSentAngle = null
        lastEmitAtMs = 0L
        // ★ **保留**最后一次样本（不 `resetSample()`），理由：
        //   * `on-change` 传感器的 HAL 在**重新注册时**会立刻补一帧当前值
        //     （CTS 要求），所以刚 `onResume` 就会自我校正；
        //   * 若在这里清空，Dart 侧会先跳成"未知/摊平"再跳回半折 ——
        //     清一次屏不如保留"最后一次已知姿态"。
        // 首次启动/从未收到事件时 `angleDegrees` 本来就是 null ⇒ Dart 侧
        // 得到 `unknown` ⇒ 布局 fail-open（这才是必须守住的那条）。
        // `detach()` 里才真正清空（桥都没了，样本无意义）。
    }

    private fun resetSample() {
        angleDegrees = null
        postureCode = null
        source = "unknown"
    }

    /**
     * 节流后推一帧给 Dart，并打一行 logcat（真机取证的原始读数就来自这里）。
     *
     * 节流依据：posture 传感器实测 ~50 Hz，全量推给 Dart 会在半折时把每一帧
     * 都变成一次 `MediaQuery` 更新；10 Hz + "变化 ≥2° 立刻发"既跟得上手速，
     * 又不会让 UI 掉帧（每步静态姿态只要 ≥100 ms 就一定会有样本落地）。
     */
    private fun emit() {
        val now = SystemClock.elapsedRealtime()
        val prev = lastSentAngle
        val cur = angleDegrees
        val delta = if (prev != null && cur != null) abs(cur - prev) else Double.MAX_VALUE
        if (now - lastEmitAtMs < MIN_EMIT_INTERVAL_MS && delta < EMIT_ON_DELTA_DEGREES) return
        lastEmitAtMs = now
        lastSentAngle = cur
        val snap = snapshot()
        Log.d(
            TAG,
            "angle=${fmt(cur)} code=${fmt(postureCode)} source=$source subscribed=$subscribed",
        )
        sink?.success(snap)
    }

    private fun fmt(v: Double?): String = v?.let { String.format("%.2f", it) } ?: "null"

    private fun snapshot(): Map<String, Any?> = mapOf(
        "angleDegrees" to angleDegrees,
        "postureCode" to postureCode,
        "source" to source,
        "subscribed" to subscribed,
    )

    // ------------------------------------------------------------------ 通道

    fun attach(context: Context, engine: FlutterEngine) {
        appContext = context.applicationContext
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                // 零延迟拉取"最后一次样本"；没有样本 ⇒ unknown（不编角度）
                "read" -> result.success(snapshot())
                "probe" -> result.success(
                    mapOf(
                        "hasHingeAngle" to (hingeSensor != null),
                        "hasPosture" to (postureSensor != null),
                        "hingeAngleType" to hingeType,
                        "postureType" to TYPE_HUAWEI_POSTURE,
                        "apiLevel" to Build.VERSION.SDK_INT,
                        "subscribed" to subscribed,
                        "source" to source,
                    ),
                )
                else -> result.notImplemented()
            }
        }

        val ec = EventChannel(engine.dartExecutor.binaryMessenger, EVENTS)
        eventChannel = ec
        ec.setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    sink = events
                    // 两个条件都满足才注册（见类注释"生命周期"）
                    if (resumed) {
                        register()
                        // 已有样本就先补一帧，Dart 侧不必等下一个事件
                        if (subscribed && angleDegrees != null) events?.success(snapshot())
                    }
                }

                override fun onCancel(arguments: Any?) {
                    sink = null
                    unregister("onCancel")
                }
            },
        )
    }

    /** Activity `onResume` → 有监听者才注册。 */
    fun onResume() {
        resumed = true
        if (sink != null) register()
    }

    /** Activity `onPause` → 立刻注销（别让传感器在后台常驻耗电）。 */
    fun onPause() {
        resumed = false
        unregister("onPause")
    }

    /** Activity `onDestroy` → 通道与传感器一起收干净。 */
    fun detach() {
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        eventChannel?.setStreamHandler(null)
        eventChannel = null
        sink = null
        resumed = false
        unregister("detach")
        resetSample()
        appContext = null
    }
}
