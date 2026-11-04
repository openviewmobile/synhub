// Phase 8：常驻通知 + 消息通知 + 通知内动作（回复/已读/贪睡）。
//
// 为什么自己写而不是用 flutter_local_notifications：
//   * 常驻 Socket 的前台 Service 反正要用 Kotlin 写，通知顺手一起做；
//   * 通知内回复要 `RemoteInput` + `BroadcastReceiver`，插件各版本行为差别大，
//     自己写能精确对齐原 App（回复走同一个 socket 会话）；
//   * 少一个依赖 = 少一次 Gradle/Maven 解析风险。
//
// 与 Dart 的接口（MethodChannel `synhub/background`）：
//   调用方向 Dart→原生：startService / stopService / isServiceRunning /
//                        showMessage / cancelMessage / cancelAll
//   回调方向 原生→Dart：onNotificationAction(action, channelId, postId, text)
//
// 通知体解密在 Dart 侧完成后才传进来（E2EE 频道不可能在原生层解）。
package com.openviewai.synhub

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import androidx.core.app.RemoteInput
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

object ChatNotifications {
    const val TAG = "ChatNotif"
    const val CHANNEL_SERVICE = "chat_service"
    const val CHANNEL_MESSAGES = "chat_messages"

    const val ACTION_REPLY = "com.openviewai.synhub.REPLY"
    const val ACTION_MARK_READ = "com.openviewai.synhub.MARK_READ"
    const val ACTION_SNOOZE = "com.openviewai.synhub.SNOOZE"

    const val EXTRA_CHANNEL_ID = "channel_id"
    const val EXTRA_POST_ID = "post_id"
    const val EXTRA_THREAD_ID = "thread_id"
    const val EXTRA_ACTION = "action"
    const val EXTRA_TEXT = "text"
    const val KEY_REPLY = "key_reply"

    /** 单条消息（不走聚合时）用的 id；正常路径由 Dart 传 notificationId 过来 */
    fun idForPost(postId: Long): Int = (postId xor (postId ushr 32)).toInt()

    /**
     * 已挂出的通知：channel_id → 该频道下已挂的话题 id 集合。
     *
     * 原版的通知是**按 (channel_id, thread_id) 聚合成一条**的
     * （`NotificationTag`，id = `HashCodeBuilder(17,31).append(channelId).append(threadId)`，
     * tag = Gson 序列化的 `{"channel_id":…,"thread_id":…}`）。
     * 同一个 (频道, 话题) 再来的消息会**原地更新**同一条通知，而不是再堆一条。
     */
    private val posted = HashMap<Long, MutableSet<Long>>()
    private var postedLoaded = false

    /// ⚠️ 必须持久化：进程重启后系统里那些通知还在，用户点「已读」得能撤掉它们
    /// （原版也是把通知记录存起来的 —— `PushNotificationUtils` 的 notificationVoList）。
    private const val PREFS = "synhub_notifs"
    private const val KEY_POSTED = "posted_threads"

    @Synchronized
    private fun loadPosted(context: Context) {
        if (postedLoaded) return
        postedLoaded = true
        val raw = context
            .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY_POSTED, null) ?: return
        try {
            val obj = org.json.JSONObject(raw)
            obj.keys().forEach { key ->
                val channelId = key.toLongOrNull() ?: return@forEach
                val arr = obj.optJSONArray(key) ?: return@forEach
                val set = HashSet<Long>()
                for (i in 0 until arr.length()) set.add(arr.optLong(i))
                if (set.isNotEmpty()) posted[channelId] = set
            }
        } catch (e: Throwable) {
            android.util.Log.w(TAG, "恢复通知记录失败：$e")
        }
    }

    @Synchronized
    private fun savePosted(context: Context) {
        val obj = org.json.JSONObject()
        posted.forEach { (channelId, set) ->
            val arr = org.json.JSONArray()
            set.forEach { arr.put(it) }
            obj.put(channelId.toString(), arr)
        }
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_POSTED, obj.toString())
            .apply()
    }

    @Synchronized
    fun rememberPosted(context: Context, channelId: Long, threadId: Long) {
        loadPosted(context)
        posted.getOrPut(channelId) { HashSet() }.add(threadId)
        savePosted(context)
    }

    @Synchronized
    fun forgetPosted(context: Context, channelId: Long, threadId: Long) {
        loadPosted(context)
        val set = posted[channelId] ?: return
        set.remove(threadId)
        if (set.isEmpty()) posted.remove(channelId)
        savePosted(context)
    }

    /** 当前挂着的 (频道, 话题) 条数 —— 决定要不要挂群摘要 */
    @Synchronized
    fun postedThreadCount(context: Context): Int {
        loadPosted(context)
        return posted.values.sumOf { it.size }
    }

    @Synchronized
    fun postedEntries(context: Context): List<Pair<Long, Long>> {
        loadPosted(context)
        return posted.entries.flatMap { (c, set) -> set.map { c to it } }
    }

    @Synchronized
    fun forgetAllPosted(context: Context) {
        posted.clear()
        savePosted(context)
    }

    /// 系统级分组：原版用 `com.synology.dschat_group` 把所有消息通知归到一组，
    /// Android 会折叠成一条摘要。
    const val GROUP_CHAT = "com.openviewai.synhub.CHAT"

    /// 摘要通知的固定 id（原版是 536870912）
    const val SUMMARY_ID = 536870912

    fun ensureChannels(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = context.getSystemService(NotificationManager::class.java) ?: return
        // ★ r341 D42：渠道名/描述**永远重写一遍**（不是 `if (null)` 才建）——
        //   Android 允许用同一 id 调 `createNotificationChannel` 更新 name/description，
        //   否则用户在 App 里换了语言，系统「应用 → 通知」里的渠道名会**永远停在第一次创建时的语言**。
        //   口径也必须统一：走 `AppLang.s`（App 内语言），**不是** `context.getString`（系统语言），
        //   更不是硬编码中文（英文界面会显示中文）。
        nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL_SERVICE,
                AppLang.s(context, R.string.chat_service_channel),
                NotificationManager.IMPORTANCE_MIN,
            ).apply {
                description = AppLang.s(context, R.string.chat_service_channel_desc)
                setShowBadge(false)
            },
        )
        nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL_MESSAGES,
                AppLang.s(context, R.string.chat_messages_channel),
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = AppLang.s(context, R.string.chat_messages_channel_desc)
            },
        )
    }

    /** 常驻通知（前台 Service 必须有） */
    fun buildServiceNotification(context: Context, title: String, text: String): Notification {
        ensureChannels(context)
        val open = PendingIntent.getActivity(
            context,
            0,
            Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            pendingFlags(),
        )
        return NotificationCompat.Builder(context, CHANNEL_SERVICE)
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
            .setShowWhen(false)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setContentIntent(open)
            .build()
    }

    /**
     * 一条消息通知。
     *
     * * `title` = 频道名 / 发送者，`text` = 已经解好密的消息体（Dart 侧给）；
     * * 动作：回复（RemoteInput）、标记已读、贪睡 60 分钟（与原版一致）；
     * * 全部动作都通过 [NotificationActionReceiver] 回到 Dart。
     */
    fun buildMessageNotification(
        context: Context,
        channelId: Long,
        postId: Long,
        title: String,
        text: String,
        canReply: Boolean,
        threadId: Long = 0L,
        notificationId: Int = idForPost(postId),
        lines: List<String> = emptyList(),
    ): Notification {
        ensureChannels(context)
        val open = PendingIntent.getActivity(
            context,
            notificationId,
            Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                .putExtra(EXTRA_CHANNEL_ID, channelId)
                .putExtra(EXTRA_POST_ID, postId)
                .putExtra(EXTRA_THREAD_ID, threadId),
            pendingFlags(),
        )

        // 多条聚合成一条时用 InboxStyle（原版 `getInboxStyleAndTitle`）：
        // 大标题 = "N 条新消息 | 频道名"，明细最多 5 行
        val style = if (lines.size >= 2) {
            NotificationCompat.InboxStyle()
                .setBigContentTitle(title)
                .also { st -> lines.takeLast(5).forEach { st.addLine(it) } }
        } else {
            NotificationCompat.BigTextStyle().bigText(text)
        }

        val builder = NotificationCompat.Builder(context, CHANNEL_MESSAGES)
            .setGroup(GROUP_CHAT)
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(style)
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(open)
            .setWhen(System.currentTimeMillis())

        if (canReply) {
            val replyIntent = Intent(context, NotificationActionReceiver::class.java)
                .setAction(ACTION_REPLY)
                .putExtra(EXTRA_CHANNEL_ID, channelId)
                .putExtra(EXTRA_POST_ID, postId)
                .putExtra(EXTRA_THREAD_ID, threadId)
            // ⚠️ 带 RemoteInput 的 PendingIntent 在 Android 12+ **必须**是
            // FLAG_MUTABLE，否则系统直接拒收这条通知：
            //   "PendingIntents attached to actions with remote inputs must be mutable"
            // （真机 LGE AN10 / API 31 上就是这样，通知一条都弹不出来）
            val replyPending = PendingIntent.getBroadcast(
                context,
                notificationId + REPLY_OFFSET,
                replyIntent,
                pendingFlags(mutable = true),
            )
            val input = RemoteInput.Builder(KEY_REPLY)
                .setLabel(AppLang.s(context, R.string.chat_reply_hint))
                .build()
            builder.addAction(
                NotificationCompat.Action.Builder(
                    android.R.drawable.ic_menu_send,
                    "回复",
                    replyPending,
                ).addRemoteInput(input).build(),
            )
        }

        builder.addAction(
            android.R.drawable.checkbox_on_background,
            "已读",
            actionPending(
                context, ACTION_MARK_READ, channelId, postId, threadId, MARK_READ_OFFSET,
            ),
        )
        builder.addAction(
            android.R.drawable.ic_menu_recent_history,
            "贪睡",
            actionPending(
                context, ACTION_SNOOZE, channelId, postId, threadId, SNOOZE_OFFSET,
            ),
        )
        return builder.build()
    }

    /**
     * 群摘要（原版 `NotificationHelper` 用 `NotificationGroup(GROUP_KEY, true)` +
     * 固定 id `NOTIFICATION_ID_SUMMARY`）。只有 ≥1 条消息通知时才挂，
     * 全撤掉后也要把它撤掉，否则 Android 会留一个空组头。
     */
    fun buildSummaryNotification(context: Context, text: String): Notification {
        ensureChannels(context)
        val open = PendingIntent.getActivity(
            context,
            0,
            Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            pendingFlags(),
        )
        return NotificationCompat.Builder(context, CHANNEL_MESSAGES)
            .setGroup(GROUP_CHAT)
            .setGroupSummary(true)
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            // 应用名走资源（values/values-zh），跟着系统语言变
            .setContentTitle(context.getString(R.string.app_name))
            .setContentText(text)
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setContentIntent(open)
            .setShowWhen(false)
            .build()
    }

    /// 挂一条消息通知（带 tag，跟原版一样同一个 (频道, 话题) 原地更新）
    fun showMessage(
        context: Context,
        notification: Notification,
        notificationId: Int,
        tag: String,
        channelId: Long,
        threadId: Long,
    ) {
        notifyTag(context, notificationId, tag, notification)
        rememberPosted(context, channelId, threadId)
        val n = postedThreadCount(context)
        notifyTag(
            context,
            SUMMARY_ID,
            SUMMARY_TAG,
            buildSummaryNotification(context, "$n 个会话有新消息"),
        )
    }

    /** 撤掉一个频道下所有话题的通知，并同步群摘要 */
    fun cancelChannel(context: Context, channelId: Long) {
        loadPosted(context)
        val threads = posted[channelId]?.toList().orEmpty()
        threads.forEach { cancelTag(context, channelId, it) }
        posted.remove(channelId)
        savePosted(context)
        syncSummary(context)
    }

    /** 撤掉一个 (频道, 话题) 的通知，并同步群摘要 */
    fun cancelTag(context: Context, channelId: Long, threadId: Long) {
        val nm = NotificationManagerCompat.from(context)
        nm.cancel(tagName(channelId, threadId), notificationId(channelId, threadId))
        forgetPosted(context, channelId, threadId)
        syncSummary(context)
    }

    private fun syncSummary(context: Context) {
        val n = postedThreadCount(context)
        val nm = NotificationManagerCompat.from(context)
        if (n <= 0) {
            nm.cancel(SUMMARY_TAG, SUMMARY_ID)
        } else {
            nm.notify(
                SUMMARY_TAG,
                SUMMARY_ID,
                buildSummaryNotification(context, "$n 个会话有新消息"),
            )
        }
    }

    /** 原版 `NotificationTag.getId()`：`HashCodeBuilder(17, 31).append(c).append(t)` */
    fun notificationId(channelId: Long, threadId: Long): Int {
        var total = 17
        total = total * 31 + (channelId xor (channelId ushr 32)).toInt()
        total = total * 31 + (threadId xor (threadId ushr 32)).toInt()
        return total
    }

    /** 原版 `NotificationTag.getName()`：Gson 序列化的 tag 串 */
    fun tagName(channelId: Long, threadId: Long): String =
        "{\"channel_id\":$channelId,\"thread_id\":$threadId}"

    const val REPLY_OFFSET = 3
    const val MARK_READ_OFFSET = 1
    const val SNOOZE_OFFSET = 2
    const val SUMMARY_TAG = "synhub_summary"


    private fun actionPending(
        context: Context,
        action: String,
        channelId: Long,
        postId: Long,
        threadId: Long,
        offset: Int,
    ): PendingIntent {
        val intent = Intent(context, NotificationActionReceiver::class.java)
            .setAction(action)
            .putExtra(EXTRA_CHANNEL_ID, channelId)
            .putExtra(EXTRA_POST_ID, postId)
            .putExtra(EXTRA_THREAD_ID, threadId)
        return PendingIntent.getBroadcast(
            context,
            notificationId(channelId, threadId) + offset,
            intent,
            pendingFlags(),
        )
    }

    /// [mutable] 只给挂 RemoteInput 的“回复”动作用（Android 12+ 的硬要求）；
    /// 其余（打开 App、已读、贪睡、清除）继续用 IMMUTABLE，别放宽权限。
    private fun pendingFlags(mutable: Boolean = false): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val base = PendingIntent.FLAG_UPDATE_CURRENT
            if (mutable && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                base or PendingIntent.FLAG_MUTABLE
            } else {
                base or PendingIntent.FLAG_IMMUTABLE
            }
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }

    fun notifyTag(context: Context, id: Int, tag: String, notification: Notification) {
        try {
            val nm = NotificationManagerCompat.from(context)
            nm.notify(tag, id, notification)
            android.util.Log.d(TAG, "notify tag=$tag id=$id scheduled")
        } catch (e: SecurityException) {
            android.util.Log.w(TAG, "notify 被拒 id=$id: ${e.message}")
        } catch (e: Throwable) {
            android.util.Log.w(TAG, "notify 失败 id=$id: $e")
        }
    }

    fun notify(context: Context, id: Int, notification: Notification) {
        try {
            val nm = NotificationManagerCompat.from(context)
            nm.notify(id, notification)
            android.util.Log.d(
                TAG,
                "notify id=$id enabled=${nm.areNotificationsEnabled()} " +
                    "active=${nm.activeNotifications.size}",
            )
        } catch (e: SecurityException) {
            // 用户没给通知权限：静默（原 App 也只在设置里提示）
            android.util.Log.w(TAG, "notify 被拒 id=$id: ${e.message}")
        } catch (e: Throwable) {
            android.util.Log.w(TAG, "notify 失败 id=$id: $e")
        }
    }
}

/** 通知里的回复 / 已读 / 贪睡 → 回传给 Dart（引擎还活着时） */
class NotificationActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        val channelId = intent.getLongExtra(ChatNotifications.EXTRA_CHANNEL_ID, 0L)
        val postId = intent.getLongExtra(ChatNotifications.EXTRA_POST_ID, 0L)
        val threadId = intent.getLongExtra(ChatNotifications.EXTRA_THREAD_ID, 0L)
        val text = if (action == ChatNotifications.ACTION_REPLY) {
            RemoteInput.getResultsFromIntent(intent)
                ?.getCharSequence(ChatNotifications.KEY_REPLY)
                ?.toString()
                ?: ""
        } else {
            ""
        }
        // 回复/已读后立刻撤掉这条通知（原 App 同款：按 tag 撤，并同步群摘要）
        if (action == ChatNotifications.ACTION_REPLY ||
            action == ChatNotifications.ACTION_MARK_READ
        ) {
            ChatNotifications.cancelTag(context, channelId, threadId)
        }
        BackgroundBridge.dispatchAction(context, action, channelId, postId, text)
    }
}
