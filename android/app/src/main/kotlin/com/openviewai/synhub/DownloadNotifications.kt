package com.openviewai.synhub

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * ⑥下载 F12：**下载完成通知**（本地通知，不依赖 FCM）。
 *
 * 事实来源：官方 DSdownload 用前台 Service + 通知做完成提醒；本仓库已有
 * `ChatNotifications` 的通知基建（channel + PendingIntent + 权限探测），
 * 这里复用它并把「发一条完成通知」暴露成 Dart 可调的方法通道。
 *
 * 通道：`synhub/download_notifications`
 * * `available` → Boolean（是否允许发通知：Android 13+ 需要 POST_NOTIFICATIONS）
 * * `show` (id, title, text) → null（幂等，同 id 覆盖）
 */
object DownloadNotifications {
    const val CHANNEL = "synhub/download_notifications"
    const val CHANNEL_ID = "download_finished"

    fun attach(messenger: BinaryMessenger, context: Context) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "available" -> result.success(available(context))
                "show" -> {
                    val id = call.argument<Int>("id") ?: 0
                    val title = call.argument<String>("title") ?: ""
                    val text = call.argument<String>("text") ?: ""
                    show(context, id, title, text)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /** Android 13+ 未授权就是 false（fail-closed：界面据此提示，不静默丢通知）。 */
    fun available(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        return context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) ==
            android.content.pm.PackageManager.PERMISSION_GRANTED
    }

    fun show(context: Context, id: Int, title: String, text: String) {
        if (!available(context)) return
        ensureChannel(context)
        val open = PendingIntent.getActivity(
            context,
            id,
            Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val n = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentTitle(title)
            .setContentText(text)
            .setAutoCancel(true)
            .setContentIntent(open)
            .build()
        context.getSystemService(NotificationManager::class.java)?.notify(id, n)
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = context.getSystemService(NotificationManager::class.java) ?: return
        // ★ r341 D42：口径同 ChatNotifications —— 走 AppLang.s 且**每次重写**（换语言要跟着变）。
        nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                AppLang.s(context, R.string.download_done_channel),
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = AppLang.s(context, R.string.download_done_channel_desc)
            },
        )
    }
}
