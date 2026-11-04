// ★★★ ③Drive 第 228 轮 **D65 原生常驻监听的前台通道**。
//
// 通道 `synhub/drive_watch`（Dart 侧 `driveWatchBridgeProvider`）：
//   * `registerCallback {handle: Long}` → Bool（Dart 先把自己的后台入口 handle 交上来）
//   * `start {roots: [String], debounce_seconds: Long, max_depth: Int}` → Bool
//   * `stop` → Bool
//   * `isRunning` → Bool
//
// 传进来的 `debounce_seconds`/`max_depth` 会与 Kotlin 常量做**一致性校验**：
// 不等于（Dart 改了常量而原生没收口）就**直接报错**，免得两侧悄悄漂移。
package com.openviewai.synhub

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

object DriveFileWatchBridge {

    const val CHANNEL = "synhub/drive_watch"

    fun attach(messenger: BinaryMessenger, context: Context) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "registerCallback" -> {
                    val handle = (call.argument<Number>("handle") ?: 0L).toLong()
                    DriveWatchWorker.rememberCallbackHandle(context, handle)
                    result.success(handle != 0L)
                }
                "start" -> handleStart(context, call, result)
                "stop" -> {
                    DriveFileWatchService.stop(context)
                    result.success(true)
                }
                "isRunning" -> result.success(DriveFileWatchService.isRunning(context))
                else -> result.notImplemented()
            }
        }
    }

    private fun handleStart(
        context: Context,
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val roots = call.argument<List<String>>("roots") ?: emptyList()
        val debounce = (call.argument<Number>("debounce_seconds") ?: -1).toLong()
        val depth = (call.argument<Number>("max_depth") ?: -1).toInt()
        if (debounce != DriveFileWatchService.DEBOUNCE_SECONDS) {
            result.error(
                "bad_debounce",
                "去抖常量不一致：收到 ${debounce}s，原生要求 ${DriveFileWatchService.DEBOUNCE_SECONDS}s",
                null,
            )
            return
        }
        if (depth != DriveFileWatchService.MAX_DEPTH) {
            result.error(
                "bad_depth",
                "深度上限不一致：收到 $depth，原生要求 ${DriveFileWatchService.MAX_DEPTH}",
                null,
            )
            return
        }
        if (roots.isEmpty()) {
            result.error("no_roots", "没有要监听的根", null)
            return
        }
        // 后台唤醒需要 Dart 侧入口 —— handle 由 `registerCallback` 交上来
        // （Kotlin 侧没有"函数名 → handle"的 API，必须由 Dart 给）。
        // ★ 249 轮：把"系统拒绝启动"如实回给 Dart（false），而不是假装成功
        result.success(DriveFileWatchService.start(context, roots))
    }
}
