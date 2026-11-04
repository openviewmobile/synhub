// 主屏快捷方式（文件模块 M72 的 Android 侧实现）。
//
// Dart 侧契约（**由 `lib/src/features/files/file_shortcut.dart` 固定，不要改**）：
//   * 通道 `synhub/shortcut`
//   * 方法 `pinShortcut`，入参 `{id, label, path}`，返回 **Bool**
//     （true = 系统已受理"请求固定"；false = 不支持/失败，Dart 侧不报错、不崩）
//   * 方法 `consumePendingPath`，返回 **String?**：
//     如果 App 是**由快捷方式冷启动/前台唤起**的，返回该快捷方式带的目录 path
//     （Dart 侧可据此跳到那个目录；没有则 null）。
//
// 为什么用 `ShortcutManagerCompat` 而不是裸 `ShortcutManager`：
//   * 它内部按 API 级别分派（`requestPinShortcut` 要 API 26+），并用
//     **launcher 回传的 IntentSender** 判断"这台设备/launcher 是否支持固定"，
//     比 `Build.VERSION` 硬判更准；`isRequestPinShortcutSupported` 直接给答案，
//     所以**不需要任何权限**（`INSTALL_SHORTCUT` 只有给老 launcher 发
//     legacy 广播才需要，Android 8+ 的 pin 流程不需要）。
//   * 官方 DSfile 的"添加到主屏幕"也就是这一套：`ShortcutManager.requestPinShortcut`。
//
// 点开快捷方式落到"那个目录"的方式：**显式 Intent**（`setClass` 指向 MainActivity，
// 所以**不需要**在 AndroidManifest 里加 intent-filter / deep link），
// 把 path 放进 extra，MainActivity 的 onCreate/onNewIntent 转交给本桥，
// Dart 侧调 `consumePendingPath` 取走（取走即清，避免重复跳转）。
package com.openviewai.synhub

import android.app.Activity
import android.content.Context
import android.content.Intent
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

object ShortcutBridge {
    const val CHANNEL = "synhub/shortcut"

    /** 快捷方式启动 Intent 里的 extra key（Dart 侧不感知，只由本桥消费）。 */
    private const val EXTRA_PATH = "synhub.shortcut_path"

    /** 自定义 action：与普通启动区分开，便于日后排查。 */
    private const val ACTION_OPEN = "com.openviewai.synhub.SHORTCUT_OPEN"

    /** 待 Dart 取走的目录（`consumePendingPath` 取走即清）。 */
    @Volatile
    private var pendingPath: String? = null

    /** 记录"由快捷方式带来的 path"。Activity 的 onCreate/onNewIntent 调用。 */
    fun handleIntent(intent: Intent?) {
        val i = intent ?: return
        if (i.action != ACTION_OPEN) return
        val p = i.getStringExtra(EXTRA_PATH)
        if (!p.isNullOrEmpty()) pendingPath = p
    }

    fun attach(activity: Activity, engine: FlutterEngine) {
        val context: Context = activity.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pinShortcut" -> {
                        val id = call.argument<String>("id").orEmpty()
                        val label = call.argument<String>("label").orEmpty()
                        val path = call.argument<String>("path").orEmpty()
                        if (id.isEmpty() || label.isEmpty()) {
                            result.error("bad_args", "id/label 不能为空", null)
                        } else {
                            result.success(pin(context, id, label, path))
                        }
                    }
                    "consumePendingPath" -> {
                        val p = pendingPath
                        pendingPath = null
                        result.success(p)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * 请求把快捷方式固定到主屏。**任何异常都吞成 false**——Dart 侧已按
     * "false = 不支持/失败"处理（弹提示但不崩），这里不能让异常穿到平台层。
     */
    private fun pin(context: Context, id: String, label: String, path: String): Boolean {
        return try {
            if (!ShortcutManagerCompat.isRequestPinShortcutSupported(context)) return false

            val intent = Intent(ACTION_OPEN).apply {
                setClass(context, MainActivity::class.java)
                putExtra(EXTRA_PATH, path)
                // singleTop：App 在前台时走 onNewIntent，不会叠一个新的 Activity
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            val info = ShortcutInfoCompat.Builder(context, id)
                .setShortLabel(label)
                .setLongLabel(label)
                .setIcon(IconCompat.createWithResource(context, R.mipmap.ic_launcher))
                .setIntent(intent)
                .build()
            // callback 传 null：不关心"用户是否点了确认"，只回报"请求是否发出"
            ShortcutManagerCompat.requestPinShortcut(context, info, null)
        } catch (t: Throwable) {
            false
        }
    }
}
