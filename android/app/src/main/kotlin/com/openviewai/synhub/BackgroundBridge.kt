// Phase 8：Dart ↔ 原生 的通知/前台服务桥。
//
// 保持一个静态引用，通知动作（BroadcastReceiver 触发）能随时回传 Dart；
// 引擎不在（App 被划掉）时只记日志——那种场景发不出消息，符合 §4.4 的取舍。
package com.openviewai.synhub

import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

object BackgroundBridge {
    const val CHANNEL = "synhub/background"
    private const val TAG = "SynologyChatBg"

    private var channel: MethodChannel? = null

    /** 原生→Dart 的通知动作（回复/已读/贪睡） */
    fun dispatchAction(
        context: Context,
        action: String,
        channelId: Long,
        postId: Long,
        text: String,
    ) {
        val ch = channel
        if (ch == null) {
            Log.w(TAG, "动作 $action 到达时 Dart 引擎已不在，忽略")
            return
        }
        ch.invokeMethod(
            "onNotificationAction",
            mapOf(
                "action" to action,
                "channelId" to channelId,
                "postId" to postId,
                "text" to text,
            ),
        )
    }

    fun attach(context: Context, engine: FlutterEngine) {
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        channel = ch
        val appContext = context.applicationContext
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "startService" -> {
                    val title = call.argument<String>("title") ?: "Synology Chat"
                    val text = call.argument<String>("text") ?: AppLang.s(appContext, R.string.chat_connecting_foreground)
                    // ★ 第 278 轮：把**系统接受与否**如实回给 Dart
                    // （Android 12+ 后台启动前台服务会被拒 →
                    //  `ForegroundServiceStartNotAllowedException`，属预期失败，
                    //  不能吞掉、更不能崩）。Dart 侧紧接着 `isRunning()` 复核，
                    //  失败时设置页会显示"未在后台保持"。
                    result.success(ChatForegroundService.start(appContext, title, text))
                }
                "stopService" -> {
                    ChatForegroundService.stop(appContext)
                    result.success(true)
                }
                "isServiceRunning" -> result.success(ChatForegroundService.running)
                "showMessage" -> {
                    val channelId = (call.argument<Number>("channelId") ?: 0).toLong()
                    val postId = (call.argument<Number>("postId") ?: 0).toLong()
                    val threadId = (call.argument<Number>("threadId") ?: 0).toLong()
                    val title = call.argument<String>("title") ?: ""
                    val text = call.argument<String>("text") ?: ""
                    val canReply = call.argument<Boolean>("canReply") ?: false
                    val lines = call.argument<List<String>>("lines") ?: emptyList()
                    // Dart 侧算好 id/tag（跟原版 NotificationTag 一致），原生只管挂
                    val notificationId =
                        (call.argument<Number>("notificationId") ?: 0).toInt()
                            .takeIf { it != 0 }
                            ?: ChatNotifications.notificationId(channelId, threadId)
                    val tag = call.argument<String>("tag")
                        ?: ChatNotifications.tagName(channelId, threadId)
                    ChatNotifications.showMessage(
                        appContext,
                        ChatNotifications.buildMessageNotification(
                            appContext, channelId, postId, title, text, canReply,
                            threadId, notificationId, lines,
                        ),
                        notificationId,
                        tag,
                        channelId,
                        threadId,
                    )
                    result.success(true)
                }
                "cancelMessage" -> {
                    val postId = (call.argument<Number>("postId") ?: 0).toLong()
                    androidx.core.app.NotificationManagerCompat.from(appContext)
                        .cancel(ChatNotifications.idForPost(postId))
                    result.success(true)
                }
                "cancelTag" -> {
                    val channelId = (call.argument<Number>("channelId") ?: 0).toLong()
                    val threadId = (call.argument<Number>("threadId") ?: 0).toLong()
                    ChatNotifications.cancelTag(appContext, channelId, threadId)
                    result.success(true)
                }
                "cancelChannel" -> {
                    val channelId = (call.argument<Number>("channelId") ?: 0).toLong()
                    ChatNotifications.cancelChannel(appContext, channelId)
                    result.success(true)
                }
                "cancelAll" -> {
                    androidx.core.app.NotificationManagerCompat.from(appContext)
                        .cancelAll()
                    ChatNotifications.forgetAllPosted(appContext)
                    result.success(true)
                }
                "notificationTags" -> {
                    // 集成测试用：把当前挂着的通知的 tag/id/标题/InboxStyle 明细读出来，
                    // 用来在真机上证明"同一 (频道,话题) 只挂一条 + 有摘要行"
                    val nm = androidx.core.app.NotificationManagerCompat.from(appContext)
                    @Suppress("DEPRECATION")
                    val list = nm.activeNotifications.map { sbn ->
                        val extras = sbn.notification.extras
                        val lines = extras
                            .getCharSequenceArray(
                                androidx.core.app.NotificationCompat.EXTRA_TEXT_LINES,
                            )
                            ?.map { it.toString() }
                            ?: emptyList<String>()
                        mapOf(
                            "tag" to (sbn.tag ?: ""),
                            "id" to sbn.id,
                            "title" to (extras
                                .getCharSequence(
                                    androidx.core.app.NotificationCompat.EXTRA_TITLE,
                                )
                                ?.toString() ?: ""),
                            // 单条通知的正文（提醒通知的文案在这里，不在 lines 里）
                            "text" to (extras
                                .getCharSequence(
                                    androidx.core.app.NotificationCompat.EXTRA_TEXT,
                                )
                                ?.toString() ?: ""),
                            "lines" to lines,
                        )
                    }
                    result.success(list)
                }
                "notificationCount" -> {
                    // 集成测试用：当前挂着的消息通知条数
                    val nm = androidx.core.app.NotificationManagerCompat.from(appContext)
                    @Suppress("DEPRECATION")
                    result.success(nm.activeNotifications.size)
                }
                "requestNotificationPermission" -> {
                    val activity = MainActivity.current
                    if (activity != null &&
                        Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                        activity.checkSelfPermission(
                            android.Manifest.permission.POST_NOTIFICATIONS,
                        ) != android.content.pm.PackageManager.PERMISSION_GRANTED
                    ) {
                        activity.requestPermissions(
                            arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
                            9001,
                        )
                    }
                    result.success(true)
                }
                "setAutostart" -> {
                    val boot = call.argument<Boolean>("boot") ?: false
                    val foreground = call.argument<Boolean>("foreground") ?: false
                    appContext
                        .getSharedPreferences("synhub", Context.MODE_PRIVATE)
                        .edit()
                        .putBoolean("autostart", boot)
                        .putBoolean("autostartForeground", foreground)
                        .apply()
                    result.success(true)
                }
                "getAutostart" -> {
                    val prefs = appContext
                        .getSharedPreferences("synhub", Context.MODE_PRIVATE)
                    result.success(
                        mapOf(
                            "boot" to prefs.getBoolean("autostart", false),
                            "foreground" to prefs.getBoolean("autostartForeground", false),
                        ),
                    )
                }
                "openChannelIntent" -> {
                    val intent = Intent(appContext, MainActivity::class.java)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        .putExtra(
                            ChatNotifications.EXTRA_CHANNEL_ID,
                            (call.argument<Number>("channelId") ?: 0).toLong(),
                        )
                    appContext.startActivity(intent)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    fun detach() {
        channel = null
    }
}
