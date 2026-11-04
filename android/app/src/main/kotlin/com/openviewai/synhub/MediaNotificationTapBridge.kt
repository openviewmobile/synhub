package com.openviewai.synhub

import android.content.Intent
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * r653（`DA257`）：**点媒体通知要回到"正在播放"那一屏**。
 *
 * ## 为什么之前回不到
 * 真机日志（`logcat -b events` ＋ `ActivityTaskManager: START u0`）证明：
 * 点通知栏那张卡，系统发过来的 intent 是
 * `act=com.ryanheise.audioservice.NOTIFICATION_CLICK cmp=…/.MainActivity`
 * —— 也就是 **audio_service 自己的 contentIntent**（`AudioService.java:64`
 * 的常量、`:400` 里 `intent.setAction(NOTIFICATION_CLICK_ACTION)`）。
 * 它和"点桌面图标"（`ACTION_MAIN`）**可以区分**，App 之前只是没看这个 action
 * ⇒ 于是统一按"恢复上次页面"处理：用户正在 Chat 里，点一下媒体卡还留在 Chat。
 *
 * ## 这里做什么
 * 只做一件事：把这**一个** action 认出来，通知 Dart（`onMediaNotificationTap`）。
 * 落到哪一屏由 Dart 决定（电台进播放面板、歌曲进单曲页，与迷你条同一个入口），
 * 原生侧**不**猜页面、不持有路由。
 *
 * ## 冷启动 / 前台两条路
 * * 冷启动：`onCreate` 里的 intent 也带这个 action ⇒ 先存 `pending`，
 *   `attach()`（引擎就绪）时补发一次；Dart 侧再用 `getPending` **取走即清**兜底
 *   （两条路都可能先到，所以 Dart 侧要幂等）。
 * * 前台：`onNewIntent`（Manifest 里 MainActivity 是 singleTop）⇒ 直接发事件。
 */
object MediaNotificationTapBridge {
    private const val CHANNEL = "synhub/media_notification_tap"

    /** 逐字抄 `audio_service-0.18.19/.../AudioService.java:64`（别改，改了就对不上）。 */
    private const val NOTIFICATION_CLICK_ACTION =
        "com.ryanheise.audioservice.NOTIFICATION_CLICK"

    private var channel: MethodChannel? = null
    private var pending = false

    fun attach(engine: FlutterEngine) {
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    // 取走即清：同一次点击不会被消费两次
                    "getPending" -> {
                        result.success(pending)
                        pending = false
                    }
                    else -> result.notImplemented()
                }
            }
        }
        // 冷启动：intent 先到了，引擎后才就绪
        if (pending) channel?.invokeMethod("onMediaNotificationTap", null)
    }

    fun handleIntent(intent: Intent?) {
        if (intent?.action != NOTIFICATION_CLICK_ACTION) return
        pending = true
        channel?.invokeMethod("onMediaNotificationTap", null)
    }
}
