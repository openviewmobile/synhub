package com.openviewai.synhub

import android.content.Context
import android.content.Intent
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 主屏小组件的**平台通道 + 点击落点**。
 *
 * Dart 侧契约（**由 `lib/src/features/widgets/widget_bridge.dart` 固定，改动两边同步**）：
 * 通道 `synhub/widget`
 *
 *   * `pushSnapshot({snapshot: String})` → **Bool**
 *     落盘快照（[WidgetSnapshotStore]）并立刻 `updateAppWidget` 全部实例。
 *     `true` = 已落盘；`false` = JSON 不认识 / 磁盘出错（Dart 侧安静降级）。
 *   * `requestRefresh()` → **Bool**
 *     按已落盘快照重画（不传新数据）。
 *   * `takePendingTarget()` → **String?**
 *     取走"由小组件点击带来的落点"（**取走即清**，同
 *     `ShortcutBridge.consumePendingPath` 语义）。
 *
 * 反向事件：`onWidgetAction`（无参）—— App 已在前台时又点了一次小组件
 * （`MainActivity` 是 `singleTop`，走 `onNewIntent`）。Dart 侧收到后调
 * `takePendingTarget()` 取落点。
 *
 * ## 点击落点为什么用**显式 Intent** 而不是 `synochat://`
 * `synochat` 那四条 scheme 是**官方别的 App 的深链**（审计行 262，带
 * `address`/`account` 参数、语义是"登录到某台 NAS"），拿它当"打开相册 tab"
 * 会污染那条链路的语义。显式 Intent（`setClass` 指向 `MainActivity`）
 * 不需要在 manifest 里加 intent-filter，也不会被别的 App 伪造唤起。
 */
object SynologyWidgetBridge {

    /** Android 侧通道名，Dart 侧 `MethodChannelWidgetBridge.channelName` 逐字相同。 */
    const val CHANNEL = "synhub/widget"

    /** 小组件点击的自定义 action（与普通启动、快捷方式、分享区分开，便于排查）。 */
    const val ACTION_OPEN = "com.openviewai.synhub.WIDGET_OPEN"

    /** 落点 extra。Dart 侧 `parseWidgetTarget` 解析。 */
    const val EXTRA_TARGET = "synhub.widget_target"

    private var channel: MethodChannel? = null

    /** 待 Dart 取走的落点（`takePendingTarget` 取走即清）。 */
    @Volatile
    private var pendingTarget: String? = null

    fun attach(context: Context, engine: FlutterEngine) {
        val appContext = context.applicationContext
        val store = WidgetSnapshotStore(appContext)
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "pushSnapshot" -> {
                        val json = call.argument<String>("snapshot")
                        val ok = store.save(json)
                        if (ok) refreshAll(appContext)
                        result.success(ok)
                    }
                    "requestRefresh" -> {
                        refreshAll(appContext)
                        result.success(true)
                    }
                    "takePendingTarget" -> {
                        val t = pendingTarget
                        pendingTarget = null
                        result.success(t)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        // Activity 已经起了、attach 晚于 onCreate 时，把启动 Intent 再补看一次
        if (context is android.app.Activity) {
            handleIntent(context.intent)
        }
    }

    /** `MainActivity` 的 `onCreate` / `onNewIntent` 调用（与 `ShortcutBridge` 同构）。 */
    fun handleIntent(intent: Intent?) {
        val i = intent ?: return
        if (i.action != ACTION_OPEN) return
        val target = i.getStringExtra(EXTRA_TARGET)
        if (target.isNullOrBlank()) return
        pendingTarget = target
        channel?.invokeMethod("onWidgetAction", null)
    }

    /** 重画全部小组件实例（6 个 Provider）。 */
    fun refreshAll(context: Context) {
        PhotoGridWidgetProvider.refresh(context)
        QuickstartWidgetProvider.refresh(context)
        NotesWidgetProvider.refresh(context)
        TodosWidgetProvider.refresh(context)
        NotebookWidgetProvider.refresh(context)
        NewNoteWidgetProvider.refresh(context)
    }
}
