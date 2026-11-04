// ★★ ③Drive 第 214 轮 **D84（专注备份和同步 / 休眠备份）** 的原生半边：
// 官方 `SleepBackupActivity` 的 `handleScreenDimming` —— **把窗口调暗并保持常亮**，
// 让"屏幕变暗时继续跑备份"这件事在 Android 上真的发生。
//
// ## 官方对照（`activity/SleepBackupActivity.smali`）
//   * `WindowManager` + `countDownTimer`：倒计时结束（官方文案
//     `sleepmode_turn_dark_countdown_desc`「屏幕将在 %1$d 秒内后变暗。」）后**调暗窗口**；
//   * `sleepmode_keep_forground_desc`「请让 Synology Drive 保留在前台以继续此流程。」
//     / `sleepmode_not_exit_app_desc`「请勿锁定屏幕或退出应用程序。」⇒ 期间**保持亮屏**，
//     不让系统锁屏把任务掐掉。
//
// ## 通道契约（由 `lib/src/features/photos/sleep_backup_platform.dart` 固定）
//   * 通道 `synhub/sleep_backup`
//   * `setScreenBrightness` `{value: Double}` —— 0.0~1.0 覆盖亮度（官方调暗用的是
//     窗口级 `screenBrightness`，不改系统设置、退出即恢复）；
//   * `clearScreenBrightness` —— 恢复跟随系统（`BRIGHTNESS_OVERRIDE_NONE`）；
//   * `setKeepScreenOn` `{on: Bool}` —— `FLAG_KEEP_SCREEN_ON` 的开关。
//
// 说明：**不改系统亮度设置**（那需要 `WRITE_SETTINGS` 特殊权限，官方也不用），
// 只改当前 Activity 窗口的亮度；App 退到后台/销毁时窗口属性随之失效。
package com.openviewai.synhub

import android.app.Activity
import android.view.WindowManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

object SleepBackupBridge {

    const val CHANNEL = "synhub/sleep_backup"

    /** 官方倒计时后调的"暗"档：窗口亮度的低值（不是 0，完全黑会像死机）。 */
    private const val DIM_BRIGHTNESS = 0.02f

    fun attach(activity: Activity, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "setScreenBrightness" -> {
                    val value = (call.argument<Double>("value") ?: DIM_BRIGHTNESS.toDouble()).toFloat()
                    runOnUi(activity) {
                        val attrs = activity.window.attributes
                        attrs.screenBrightness = value.coerceIn(0.0f, 1.0f)
                        activity.window.attributes = attrs
                    }
                    result.success(true)
                }

                "clearScreenBrightness" -> {
                    runOnUi(activity) {
                        val attrs = activity.window.attributes
                        attrs.screenBrightness = WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                        activity.window.attributes = attrs
                    }
                    result.success(true)
                }

                "setKeepScreenOn" -> {
                    val on = call.argument<Boolean>("on") ?: false
                    runOnUi(activity) {
                        if (on) {
                            activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        } else {
                            activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                    }
                    result.success(true)
                }

                // ★ 249 轮：把窗口**真实状态**读回去（真机取证用）。
                // Android 的 `Window.attributes.screenBrightness` 在没有覆盖时是
                // `BRIGHTNESS_OVERRIDE_NONE`（-1f）⇒ 如实回 null，不编一个"0"。
                "getStatus" -> {
                    runOnUi(activity) {
                        val attrs = activity.window.attributes
                        val b = attrs.screenBrightness
                        val map = HashMap<String, Any?>()
                        val keep = (
                            activity.window.attributes.flags and
                                WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
                            ) != 0
                        map["keep_screen_on"] = keep
                        map["screen_brightness"] =
                            if (b == WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE) {
                                null
                            } else {
                                b.toDouble()
                            }
                        result.success(map)
                    }
                }

                else -> result.notImplemented()
            }
        }
    }

    private inline fun runOnUi(activity: Activity, crossinline block: () -> Unit) {
        if (android.os.Looper.myLooper() == android.os.Looper.getMainLooper()) {
            block()
        } else {
            activity.runOnUiThread { block() }
        }
    }
}
