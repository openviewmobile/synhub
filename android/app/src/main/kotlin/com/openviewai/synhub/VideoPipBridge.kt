package com.openviewai.synhub

import android.app.Activity
import android.app.PictureInPictureParams
import android.content.pm.PackageManager
import android.os.Build
import android.util.Rational
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * r654（`DA259`）：**视频播放器的画中画**。
 *
 * ## 为什么放在这里
 * PiP 是 Activity 级能力（`enterPictureInPictureMode`），Flutter 侧只有 `Activity`
 * 的引用，所以由原生持有 Activity、Dart 只表达意图（进 / 退 / 自动进入开关）。
 * 这与 `MediaNotificationTapBridge` 的分工一致：原生不猜页面，Dart 不碰系统 API。
 *
 * ## 两个入口
 * 1. **手动**：播放器里的画中画按钮 → `enter(width, height)`；
 * 2. **自动**（Android 12 / API 31+）：`setAutoEnterEnabled(true)` ⇒ 用户在播放中点
 *    Home / 上滑回桌面时**系统**直接把画面缩成小窗，不需要先按按钮 —— 这是
 *    "和系统播放器一样"的那一半，少了它用户会觉得"别的 App 都行，这个不行"。
 *    自动进入只在**播放中**开着，暂停时关掉：否则用户想退出去聊天，画面也跟着走。
 *
 * ## 状态回传
 * `MainActivity.onPictureInPictureModeChanged` → `onModeChanged`，Dart 侧据此
 * 收起控制条/提示条（小窗里不该有整套控件）。进/出都发，**不依赖**调用顺序：
 * 系统手势进入时 Dart 从来没调过 `enter()`。
 *
 * ## 兼容
 * `supported()` 同时看 API ≥ 26 与 `FEATURE_PICTURE_IN_PICTURE`（部分定制 ROM
 * 在低端机上裁掉该特性）；不支持时 Dart 侧**不渲染按钮**，不摆假入口。
 */
object VideoPipBridge {
    private const val CHANNEL = "synhub/video_pip"

    private var activity: Activity? = null
    private var channel: MethodChannel? = null

    /** 最近一次给的画面比例（自动进入时系统要它，否则按窗口默认） */
    private var aspect: Rational = Rational(16, 9)

    /** 自动进入是否开着（只在播放中由 Dart 打开） */
    private var autoEnter = false

    fun attach(activity: Activity, engine: FlutterEngine) {
        this.activity = activity
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "supported" -> result.success(supported())
                    "enter" -> {
                        call.argument<Int>("width")?.let { width ->
                            call.argument<Int>("height")?.let { height ->
                                aspect = safeAspect(width, height)
                            }
                        }
                        result.success(enter())
                    }
                    "setAutoEnter" -> {
                        autoEnter = call.argument<Boolean>("enabled") ?: false
                        result.success(applyParams())
                    }
                    "isInPip" -> result.success(isInPip())
                    else -> result.notImplemented()
                }
            }
        }
    }

    /** MainActivity 的 `onPictureInPictureModeChanged` 转进来 */
    fun onModeChanged(isInPip: Boolean) {
        // 出小窗后不要再自动进入（用户已经把画面收起来了）
        if (!isInPip) {
            autoEnter = false
            // ★ r661（`DA277`）：只改这个字段是不够的 —— 参数是**写死在
            // Activity 上**的（`setAutoEnterEnabled(true)` 还在），用户在小窗里
            // 点"放大"回来、再按 Home 时系统照旧按旧参数把小窗又缩出来。
            // 所以出小窗必须**重设一次参数**，让"关掉"真的落到 Activity 上。
            applyParams()
        }
        channel?.invokeMethod("onPipModeChanged", isInPip)
    }

    fun supported(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        val ctx = activity?.applicationContext ?: return false
        return ctx.packageManager.hasSystemFeature(
            PackageManager.FEATURE_PICTURE_IN_PICTURE,
        )
    }

    private fun isInPip(): Boolean {
        val a = activity ?: return false
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        return a.isInPictureInPictureMode
    }

    private fun enter(): Boolean {
        val a = activity ?: return false
        if (!supported()) return false
        return try {
            a.enterPictureInPictureMode(params())
            true
        } catch (e: IllegalStateException) {
            // 例如 Activity 正在销毁 / 系统此刻不允许 —— 预期失败不崩（AGENTS §2.0.19）
            false
        } catch (e: IllegalArgumentException) {
            false
        }
    }

    /** 只更新参数（不进入），让系统在 Home 手势时按当前比例自动缩窗 */
    private fun applyParams(): Boolean {
        val a = activity ?: return false
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        return try {
            a.setPictureInPictureParams(params())
            true
        } catch (e: IllegalStateException) {
            false
        } catch (e: IllegalArgumentException) {
            false
        }
    }

    private fun params(): PictureInPictureParams {
        val builder = PictureInPictureParams.Builder().setAspectRatio(aspect)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // 31+：手势直接进入小窗（系统播放器的默认手感）
            builder.setAutoEnterEnabled(autoEnter)
            // 进入时不要因为尺寸变化而重新布局一帧黑的
            builder.setSeamlessResizeEnabled(true)
        }
        return builder.build()
    }

    /** 0/负数一律回 16:9：`Rational` 不接受 0，抛异常会让按钮"点了没反应" */
    private fun safeAspect(width: Int, height: Int): Rational {
        if (width <= 0 || height <= 0) return Rational(16, 9)
        // 极端长条（> 2.39:1 或 < 1:2.39）系统会拒绝，夹一下
        val ratio = width.toDouble() / height.toDouble()
        if (ratio > 2.39) return Rational(239, 100)
        if (ratio < 1.0 / 2.39) return Rational(100, 239)
        return Rational(width, height)
    }
}
