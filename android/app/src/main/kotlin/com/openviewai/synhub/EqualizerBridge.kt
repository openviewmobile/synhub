package com.openviewai.synhub

import android.media.audiofx.Equalizer
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * B10 均衡器：`android.media.audiofx.Equalizer` → Dart。
 *
 * 官方 DSaudio 的做法完全一致（`playing/EqualizerSettings.java`）：直接持
 * `android.media.audiofx.Equalizer`，**段数 / 中心频率 / 电平上下限 / 预设名
 * 全部运行时从平台枚举**，官方没有硬编码任何表。这里同样不写死。
 *
 * 通道：`synhub/equalizer`
 *  * `caps`  → 入参 `{session:Int}` → `{available:Boolean, presets:[String],
 *               bands:Int, minLevel:Int, maxLevel:Int, centerFreqs:[Int]}`
 *  * `apply` → 入参 `{session:Int, enabled:Boolean, preset:String?, bands:[Int]?}`
 *
 * ## ★ 第 368 轮订正：`session` 必须是**播放器自己的会话**
 *
 * r350 起这里写死 `Equalizer(0, 0)`（全局输出混音）。真机读数
 * `RuntimeException: Cannot initialize effect engine … Error: -3`
 * = `AudioEffect.ERROR_NO_INIT`（**不是** `-4 BAD_VALUE`），而本机
 * `/system/etc/audio_effects.conf` 里**确实声明了 equalizer**（`library bundle`，
 * 标准 UUID `0bed4300-ddd6-11db-8f34-0002a5d5c51b`）、`libbundlewrapper.so` 也在，
 * `dumpsys media.audio_flinger` 还能列出 `Equalizer / NXP Software Ltd.`
 * ⇒ "本机没有效果"不成立，**失败点是全局 session 0 挂不上去**。
 *
 * 现在由 Dart 侧把**正在播放那一路的 audio session id**（`just_audio` 的
 * `androidAudioSessionId`，与真频谱桥用的是同一个 id）传进来；拿不到
 * （没在播 / 非 Android）时**回落 0**，行为与改动前完全一致，不会更差。
 *
 * ⚠️ 失败一律返回 `available=false`，**不假装生效**。
 */
object EqualizerBridge {
    private const val TAG = "EqualizerBridge"
    private const val CHANNEL = "synhub/equalizer"

    private var equalizer: Equalizer? = null
    private var channel: MethodChannel? = null

    /// 当前 Equalizer 挂着的 audio session（`-1` = 还没建）。
    private var attachedSession = -1

    /** Dart 传来的播放会话 id；拿不到（或 ≤0）时回落 `0`（全局输出混音）。 */
    private fun sessionOf(call: MethodCall): Int {
        val id = call.argument<Int>("session") ?: 0
        return if (id > 0) id else 0
    }

    fun attach(engine: FlutterEngine) {
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "caps" -> result.success(caps(sessionOf(call)))
                "apply" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    val preset = call.argument<String>("preset")
                    val bands = call.argument<List<Int>>("bands")
                    result.success(apply(sessionOf(call), enabled, preset, bands))
                }
                else -> result.notImplemented()
            }
        }
    }

    fun detach() {
        channel?.setMethodCallHandler(null)
        channel = null
        release()
    }

    private fun release() {
        try {
            equalizer?.enabled = false
            equalizer?.release()
        } catch (e: Throwable) {
            Log.w(TAG, "release failed", e)
        }
        equalizer = null
        attachedSession = -1
    }

    /**
     * 懒建 + **按会话换绑**：`sessionId > 0` = 挂到那一路播放上（正确做法），
     * `0` = 全局输出混音（旧行为，多数 ROM 会回 `ERROR_NO_INIT`）。
     * 会话变了就把旧的放掉重建。失败即如实回 `available=false`。
     */
    private fun ensure(sessionId: Int): Equalizer? {
        val target = if (sessionId > 0) sessionId else 0
        equalizer?.let { if (attachedSession == target) return it }
        if (equalizer != null) release()
        return try {
            Equalizer(0, target).also {
                equalizer = it
                attachedSession = target
            }
        } catch (e: Throwable) {
            Log.w(TAG, "Equalizer unavailable (session=$target)", e)
            attachedSession = -1
            equalizer = null
            null
        }
    }

    private fun caps(sessionId: Int): Map<String, Any> {
        val target = if (sessionId > 0) sessionId else 0
        val eq = ensure(target)
            ?: return mapOf(
                "available" to false,
                "reason" to "effect-init-failed",
                "session" to target,
            )
        return try {
            val presets = (0 until eq.numberOfPresets.toInt()).map {
                eq.getPresetName(it.toShort()).toString()
            }
            val range = eq.bandLevelRange
            mapOf(
                "available" to true,
                "session" to target,
                "presets" to presets,
                "bands" to eq.numberOfBands.toInt(),
                "minLevel" to range[0].toInt(),
                "maxLevel" to range[1].toInt(),
                "centerFreqs" to (0 until eq.numberOfBands.toInt()).map {
                    eq.getCenterFreq(it.toShort()).toInt()
                },
            )
        } catch (e: Throwable) {
            Log.w(TAG, "caps failed", e)
            mapOf("available" to false, "session" to target)
        }
    }

    private fun apply(
        sessionId: Int,
        enabled: Boolean,
        preset: String?,
        bands: List<Int>?,
    ): Boolean {
        val eq = ensure(sessionId) ?: return false
        return try {
            if (!enabled) {
                eq.enabled = false
                return true
            }
            // 自定义曲线优先（与官方一致：自定义用 setBandLevel，预设用 usePreset）
            if (bands != null && bands.isNotEmpty()) {
                val range = eq.bandLevelRange
                for (i in bands.indices) {
                    if (i >= eq.numberOfBands.toInt()) break
                    val v = bands[i].coerceIn(range[0].toInt(), range[1].toInt())
                    eq.setBandLevel(i.toShort(), v.toShort())
                }
            } else if (preset != null) {
                val idx = (0 until eq.numberOfPresets.toInt()).firstOrNull {
                    eq.getPresetName(it.toShort()).toString() == preset
                }
                eq.usePreset((idx ?: 0).toShort())
            }
            eq.enabled = true
            true
        } catch (e: Throwable) {
            Log.w(TAG, "apply failed", e)
            false
        }
    }
}
