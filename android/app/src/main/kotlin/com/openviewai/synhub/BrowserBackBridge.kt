package com.openviewai.synhub

import android.view.KeyEvent
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * ★★ DA62（第 409 轮）：**内置链接浏览器页的系统返回键**。
 *
 * **真机读到什么**（`docs/android-ui-audit-r409.md` §S2，三组同刻 `dump`）：
 *   * 该页**没加载过网页**时，`keyevent 4` 正常退回下载列表；
 *   * 只要 WebView **加载过任何一页**（哪怕是第一次加载、没有历史可回），
 *     `keyevent 4` 就**完全没反应** —— 既不退页、也不回 WebView 历史；
 *   * **焦点在 Flutter 输入框（E1）还是网页内容（E2）结果一样**，
 *     所以"谁拿着焦点"不是变量（这条否证很重要：Dart 侧的 `PopScope`
 *     救不了它，因为按键根本到不了 Flutter）。
 *
 * ⇒ 修复只能落在**视图树之上**：`Activity.dispatchKeyEvent` 先吃下返回键，
 *   再回到 Dart 执行（Dart 侧决定"收键盘 / 回历史 / 退页"）。
 *
 * **作用域**：只有 Dart 侧明确"本页在前台"时（`setActive(true)`）才吃；
 * 离开本页 Dart 立刻 `setActive(false)`（`dispose`），其它页面、其它时刻
 * 一律走 `super.dispatchKeyEvent`，**行为与改前一字不差**。
 */
object BrowserBackBridge {
    private const val CHANNEL = "synhub/browser_back"

    /** Dart 侧说"内置浏览器页现在在前台"。 */
    @Volatile
    private var armed = false

    private var channel: MethodChannel? = null

    fun attach(engine: FlutterEngine) {
        val c = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        c.setMethodCallHandler { call, result ->
            when (call.method) {
                "setActive" -> {
                    armed = call.arguments as? Boolean ?: false
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        channel = c
    }

    /** Activity 销毁时撤防（不留"吃了按键却没人处理"的状态）。 */
    fun disarm() {
        armed = false
    }

    /**
     * 返回 `true` = 这次返回键被我们吃下（Dart 已收到 `onBack`）。
     *
     * 按下与抬起**都吃**（只吃 UP 会漏 DOWN，视图树仍会看到半截事件）；
     * 动作只发一次，发在 UP 上。
     */
    fun handleKey(event: KeyEvent): Boolean {
        if (!armed) return false
        if (event.keyCode != KeyEvent.KEYCODE_BACK) return false
        if (event.action == KeyEvent.ACTION_UP) {
            channel?.invokeMethod("onBack", null)
        }
        return true
    }
}
