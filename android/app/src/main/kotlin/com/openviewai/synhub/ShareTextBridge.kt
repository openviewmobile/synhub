// ★★★ ④笔记 第 235 轮 **J9「分享笔记正文出去」的原生半边**。
//
// 通道 `synhub/share_text`：
//   * `shareText {subject, text}` → `Intent.ACTION_SEND`（`text/plain`）
//     + `Intent.createChooser`，返回 Bool（是否真的弹出了选择器）。
//
// 与既有的 `synhub/share_intent`（**入站**：别人分享给我们）方向相反，
// 名字刻意区分，避免以后两边看错方向。
package com.openviewai.synhub

import android.content.Context
import android.content.Intent
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

object ShareTextBridge {

    const val CHANNEL = "synhub/share_text"

    fun attach(messenger: BinaryMessenger, context: Context) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "shareText" -> {
                    val subject = call.argument<String>("subject") ?: ""
                    val text = call.argument<String>("text") ?: ""
                    result.success(share(context, subject, text))
                }
                else -> result.notImplemented()
            }
        }
    }

    /** 弹系统分享面板；没有可接收的 App 时返回 false（不假装成功）。 */
    private fun share(context: Context, subject: String, text: String): Boolean {
        return try {
            val send = Intent(Intent.ACTION_SEND).apply {
                type = "text/plain"
                putExtra(Intent.EXTRA_SUBJECT, subject)
                putExtra(Intent.EXTRA_TEXT, text)
            }
            val chooser = Intent.createChooser(send, subject).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(chooser)
            true
        } catch (e: Exception) {
            // 没有 Activity 能接（极少见）⇒ 如实 false
            false
        }
    }
}
