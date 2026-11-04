// 待办提醒 / 每日逾期汇总的**系统级**实现（Android 平台批 A）。
//
// 为什么自己写而不是加 `flutter_local_notifications`：
//   * 政策是「零三方依赖、自研优先」（`docs/remaining-task-plan.md` §五 #4）；
//     本文件只用 Android SDK + 既有 `androidx.core`（`NotificationCompat`，
//     `ChatNotifications.kt` 已经在用），Gradle 侧**零新依赖**。
//   * 官方 DS note 1.12.0 就是这套（证据 [E2] 见 `docs/note-b-implementation.md`）：
//       `utils/Utils.updateTodoReminderNotification(ctx, id, dueDate, offset)`：
//         `dueDate == -1 || offset == -1` → 取消；否则触发时刻
//         `(dueDate - offset) * 1000`（dueDate/offset 都是**秒**），只在未来才排。
//       `utils/Utils.updateTodoOverdueNotification(ctx, hh, mm)`：每日
//         `setInexactRepeating(..., 24h)`。
//       通知渠道 id = `Common.NOTIFICATION_CHANNEL = "dsnote"`。
//       `receivers/AlarmInitReceiver` 在 `BOOT_COMPLETED` 后重排。
//   * 通知渠道/精确闹钟/开机重排都要精确控制，插件各版本行为差别大。
//
// ⚠️ 单位换算**只有一处**，在 Dart 的 `TodoReminderPlanner.fireAtMillis`
//   （`lib/src/features/notes/note_reminder.dart`）。本文件收到的
//   `fireAtMillis` 已经是**绝对毫秒**，**不再**做 `(dueDate - offset) * 1000`。
//   `dueDate` / `reminderOffset` 只用于官方语义的**取消判定**（不参与算术）：
//   Dart 的 `dueDate <= 0` 等价官方的 `dueDate == -1`（我们的 DTO 用 0 表示无
//   截止日期），`reminderOffset == -1` 原样对应官方 `TODO_NO_REMINDER_OFFSET`。
//
// 与 Dart 的接口（MethodChannel `synhub/note_reminder`，见
// `lib/src/features/notes/note_reminder_platform.dart`）：
//   Dart→原生：status / requestPermissions / scheduleTodos / cancelAll
//   **没有**原生→Dart 的实时回调：闹钟在进程外响，通知本身就是出口。
package com.openviewai.synhub

import android.Manifest
import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

object NoteReminderPlugin {
    const val CHANNEL = "synhub/note_reminder"
    private const val TAG = "SynologyChatNote"

    /** 官方通知渠道 id（`Common.NOTIFICATION_CHANNEL = "dsnote"`）。 */
    const val CHANNEL_ID = "dsnote"

    /** 每条待办一个闹钟：`PendingIntent` 的 action（receiver 用同一个）。 */
    const val ACTION_REMINDER = "com.openviewai.synhub.NOTE_REMINDER"

    /** 每日逾期汇总的闹钟 action。 */
    const val ACTION_OVERDUE = "com.openviewai.synhub.NOTE_OVERDUE"

    const val EXTRA_ID = "note_todo_id"
    const val EXTRA_TITLE = "note_todo_title"
    const val EXTRA_DUE = "note_todo_due"

    /** `POST_NOTIFICATIONS` 运行时申请的 requestCode（与 BackgroundBridge 的 9001 区分开）。 */
    const val REQUEST_CODE_POST_NOTIFICATIONS = 9002

    /** 每日逾期汇总的固定 requestCode（`"NOTE"` 的十六进制）。 */
    private const val OVERDUE_REQUEST_CODE = 0x4E4F5445

    private const val PREFS = "synhub_note_reminder"
    private const val KEY_ALARMS = "alarms"
    private const val KEY_TODOS = "todos"
    private const val KEY_OVERDUE_ENABLED = "overdue_enabled"
    private const val KEY_OVERDUE_HOUR = "overdue_hour"
    private const val KEY_OVERDUE_MINUTE = "overdue_minute"

    private var channelRef: MethodChannel? = null

    // ------------------------------------------------------------------ 生命周期

    fun attach(context: Context, engine: FlutterEngine) {
        ensureChannel(context)
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        channelRef = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(statusMap(context))
                "requestPermissions" -> {
                    requestPermissions(context)
                    result.success(true)
                }
                "scheduleTodos" -> {
                    val ok = try {
                        scheduleTodos(context, call.arguments as? Map<*, *>)
                    } catch (e: Exception) {
                        // 不许静默失败：异常也当作"这条没排上"，Dart 会回落前台 Timer
                        Log.w(TAG, "scheduleTodos 失败", e)
                        false
                    }
                    result.success(ok)
                }
                "cancelAll" -> {
                    cancelAll(context)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    /** `MainActivity.onRequestPermissionsResult` 里转发；不是我们的 requestCode 返回 false。 */
    fun onPermissionResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != REQUEST_CODE_POST_NOTIFICATIONS) return false
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        Log.i(TAG, "POST_NOTIFICATIONS 申请结果：granted=$granted")
        // Dart 侧会在 onResume 时重新 status()，这里不用回调；只如实记录。
        return true
    }

    // ------------------------------------------------------------------ 能力/授权

    /** 三个事实：通道在 / 通知能发 / 精确闹钟能用。 */
    internal fun statusMap(context: Context): Map<String, Any> {
        val notificationsGranted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.POST_NOTIFICATIONS,
            ) == PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
        val exactAlarmAllowed = canScheduleExact(context)
        return mapOf(
            "supported" to true,
            "notificationsGranted" to notificationsGranted,
            "exactAlarmAllowed" to exactAlarmAllowed,
        )
    }

    private fun canScheduleExact(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        val am = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return false
        return am.canScheduleExactAlarms()
    }

    /**
     * 运行时申请：先通知权限（13+，会弹系统对话框）；只有通知已经能发、但精确
     * 闹钟被收回时，才拉起 `ACTION_REQUEST_SCHEDULE_EXACT_ALARM` 的授权页
     * （12+）。一次只做一件事，避免两个系统界面互相打断。
     */
    private fun requestPermissions(context: Context) {
        val activity = MainActivity.current ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.POST_NOTIFICATIONS,
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            activity.requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                REQUEST_CODE_POST_NOTIFICATIONS,
            )
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && !canScheduleExact(context)) {
            try {
                activity.startActivity(
                    Intent(
                        Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM,
                        Uri.parse("package:${context.packageName}"),
                    ),
                )
            } catch (e: Exception) {
                Log.w(TAG, "无法打开精确闹钟授权页", e)
            }
        }
    }

    // ------------------------------------------------------------------ 排程

    /**
     * 用 Dart 送来的一份 plan **整体重排**：
     *   * 先撤销 `cancelIds`（官方：`dueDate == -1 || offset == -1` → 取消）；
     *   * 再给未来时刻的每条排一个精确闹钟；
     *   * 再撤销"上一次排过、这次不在名单里"的（删除/完成/关提醒）；
     *   * 最后排每日逾期汇总（`setInexactRepeating`，24h）。
     *
     * @return false = 通知发不出去（13+ 未授权）→ 原生这条路**走不通**，Dart 必须
     *         回落前台 Timer；此时已把原生闹钟全部清掉，不留"不会响的闹钟"。
     */
    internal fun scheduleTodos(context: Context, args: Map<*, *>?): Boolean {
        val am = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager
        if (am == null) {
            Log.w(TAG, "没有 AlarmManager，无法排系统闹钟")
            return false
        }
        ensureChannel(context)

        // 官方语义的取消：Dart 已经按 `done / 无截止日期 / offset == -1 / 已过点`
        // 算好（`NoteReminderPlan.from`），这里逐条撤销。
        val cancelIds = (args?.get("cancelIds") as? List<*>)
            ?.mapNotNull { it as? String }
            .orEmpty()
        for (id in cancelIds) cancelReminder(context, am, id)

        val notificationsGranted = statusMap(context)["notificationsGranted"] == true
        if (!notificationsGranted) {
            // 通知权限没给 → 排了也不会响，如实返回 false（Dart 回落前台 Timer）
            cancelAll(context)
            return false
        }

        val alarms = args?.get("alarms") as? List<*> ?: emptyList<Any>()
        val scheduled = JSONArray()
        val validIds = HashSet<String>()
        val now = System.currentTimeMillis()
        for (raw in alarms) {
            val m = raw as? Map<*, *> ?: continue
            val id = m["id"] as? String ?: continue
            val title = m["title"] as? String ?: ""
            val due = (m["dueDate"] as? Number)?.toLong() ?: -1L
            val offset = (m["reminderOffset"] as? Number)?.toInt() ?: -1
            val fireAt = (m["fireAtMillis"] as? Number)?.toLong() ?: continue
            // 官方 gate 的**原生兜底**（正常轮不到：Dart 侧已经过滤过）
            if (due <= 0L || offset == -1) {
                cancelReminder(context, am, id)
                continue
            }
            // 官方"只在还没到点时才 setExact"
            if (fireAt <= now) {
                cancelReminder(context, am, id)
                continue
            }
            setReminderAlarm(context, am, id, title, due, fireAt)
            validIds.add(id)
            scheduled.put(
                JSONObject()
                    .put("id", id)
                    .put("title", title)
                    .put("dueDate", due)
                    .put("fireAtMillis", fireAt),
            )
        }

        // 撤销"上次排过、这次不在名单里"的（删除待办 / 标记完成 / 关掉提醒）
        for (id in loadScheduledIds(context)) {
            if (!validIds.contains(id)) cancelReminder(context, am, id)
        }

        // 截图：闹钟（开机重排用）+ 全部待办（响铃时算逾期用）
        val todosJson = JSONArray()
        val todos = args?.get("todos") as? List<*> ?: emptyList<Any>()
        for (raw in todos) {
            val m = raw as? Map<*, *> ?: continue
            val id = m["id"] as? String ?: continue
            todosJson.put(
                JSONObject()
                    .put("id", id)
                    .put("title", m["title"] as? String ?: "")
                    .put("dueDate", (m["dueDate"] as? Number)?.toLong() ?: -1L)
                    .put("done", m["done"] as? Boolean ?: false),
            )
        }

        val overdueEnabled = args?.get("overdueEnabled") as? Boolean ?: false
        val hour = (args?.get("overdueHour") as? Number)?.toInt() ?: 9
        val minute = (args?.get("overdueMinute") as? Number)?.toInt() ?: 0
        scheduleOverdue(context, am, overdueEnabled, hour, minute)

        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString(KEY_ALARMS, scheduled.toString())
            .putString(KEY_TODOS, todosJson.toString())
            .putBoolean(KEY_OVERDUE_ENABLED, overdueEnabled)
            .putInt(KEY_OVERDUE_HOUR, hour)
            .putInt(KEY_OVERDUE_MINUTE, minute)
            .apply()
        Log.i(TAG, "已排 ${scheduled.length()} 条待办闹钟，逾期汇总=$overdueEnabled $hour:$minute")
        return true
    }

    /** 撤销本 App 的全部待办闹钟 + 逾期汇总（Dart 明确要求时）。 */
    internal fun cancelAll(context: Context) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return
        for (id in loadScheduledIds(context)) cancelReminder(context, am, id)
        am.cancel(overduePendingIntent(context))
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .remove(KEY_ALARMS)
            .apply()
    }

    /**
     * 开机 / 应用更新后重排（官方 `AlarmInitReceiver` 同构）。
     *
     * 没有 Flutter 引擎时也能跑：只读本机持久化快照，不需要网络/登录。通知权限
     * 没给就整体跳过（排了也不会响）。
     */
    internal fun rescheduleFromSnapshot(context: Context) {
        if (statusMap(context)["notificationsGranted"] != true) {
            Log.i(TAG, "开机重排跳过：通知权限未授予")
            return
        }
        val am = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val now = System.currentTimeMillis()
        var count = 0
        try {
            val arr = JSONArray(prefs.getString(KEY_ALARMS, "[]"))
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                val id = o.optString("id")
                if (id.isEmpty()) continue
                val fireAt = o.optLong("fireAtMillis", -1L)
                // 已经过点的不补发（官方也只是"未来才 setExact"）
                if (fireAt <= now) continue
                setReminderAlarm(
                    context,
                    am,
                    id,
                    o.optString("title"),
                    o.optLong("dueDate", -1L),
                    fireAt,
                )
                count++
            }
        } catch (e: Exception) {
            Log.w(TAG, "开机重排：闹钟快照解析失败", e)
        }
        scheduleOverdue(
            context,
            am,
            prefs.getBoolean(KEY_OVERDUE_ENABLED, false),
            prefs.getInt(KEY_OVERDUE_HOUR, 9),
            prefs.getInt(KEY_OVERDUE_MINUTE, 0),
        )
        Log.i(TAG, "开机/更新后重排 $count 条待办闹钟")
    }

    // ------------------------------------------------------------------ 闹钟细节

    private fun setReminderAlarm(
        context: Context,
        am: AlarmManager,
        id: String,
        title: String,
        due: Long,
        fireAt: Long,
    ) {
        val pi = reminderPendingIntent(context, id, title, due)
        if (canScheduleExact(context)) {
            // 官方 setExact；这里用 setExactAndAllowWhileIdle，让 Doze 下也能准点
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, fireAt, pi)
            } else {
                am.setExact(AlarmManager.RTC_WAKEUP, fireAt, pi)
            }
        } else {
            // Android 12+ 精确闹钟未授权：**降级**为不精确（仍尽量唤醒），
            // 设置页会如实显示"精确闹钟未授权：提醒可能延迟"
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, fireAt, pi)
            } else {
                am.set(AlarmManager.RTC_WAKEUP, fireAt, pi)
            }
        }
    }

    private fun cancelReminder(context: Context, am: AlarmManager, id: String) {
        val pi = reminderPendingIntent(context, id, "", -1L)
        am.cancel(pi)
        pi.cancel()
    }

    private fun reminderPendingIntent(
        context: Context,
        id: String,
        title: String,
        due: Long,
    ): PendingIntent {
        val intent = Intent(context, NoteReminderReceiver::class.java)
            .setAction(ACTION_REMINDER)
            .putExtra(EXTRA_ID, id)
            .putExtra(EXTRA_TITLE, title)
            .putExtra(EXTRA_DUE, due)
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags = flags or PendingIntent.FLAG_IMMUTABLE
        }
        // extras 不参与 PendingIntent 匹配，requestCode 只由 id 决定 → 稳定可撤销
        return PendingIntent.getBroadcast(context, requestCodeFor(id), intent, flags)
    }

    private fun requestCodeFor(id: String): Int = id.hashCode() and 0x7FFFFFFF

    private fun overduePendingIntent(context: Context): PendingIntent {
        val intent = Intent(context, NoteReminderOverdueReceiver::class.java)
            .setAction(ACTION_OVERDUE)
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags = flags or PendingIntent.FLAG_IMMUTABLE
        }
        return PendingIntent.getBroadcast(context, OVERDUE_REQUEST_CODE, intent, flags)
    }

    /** 官方 `Utils.updateTodoOverdueNotification`：每日 `setInexactRepeating(..., 24h)`。 */
    private fun scheduleOverdue(
        context: Context,
        am: AlarmManager,
        enabled: Boolean,
        hour: Int,
        minute: Int,
    ) {
        val pi = overduePendingIntent(context)
        if (!enabled) {
            am.cancel(pi)
            return
        }
        val next = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, hour.coerceIn(0, 23))
            set(Calendar.MINUTE, minute.coerceIn(0, 59))
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }
        if (next.timeInMillis <= System.currentTimeMillis()) {
            next.add(Calendar.DAY_OF_YEAR, 1)
        }
        am.setInexactRepeating(
            AlarmManager.RTC_WAKEUP,
            next.timeInMillis,
            AlarmManager.INTERVAL_DAY,
            pi,
        )
    }

    // ------------------------------------------------------------------ 通知

    internal fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = context.getSystemService(NotificationManager::class.java) ?: return
        // ★ r341 D42：`context.getString` 跟随**系统**语言，App 内语言切到中文也不变
        //   ⇒ 改用 `AppLang.s`（与第 41 轮立的原生可见文案口径一致），并每次重写。
        val name = AppLang.s(context, R.string.note_reminder_channel)
        nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                name,
                NotificationManager.IMPORTANCE_HIGH,
            ).apply { description = name },
        )
    }

    private fun openAppIntent(context: Context): PendingIntent {
        val intent = Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags = flags or PendingIntent.FLAG_IMMUTABLE
        }
        return PendingIntent.getActivity(context, 0, intent, flags)
    }

    /** 单条待办提醒（官方 `TodoNotificationReceiver` 的提醒分支）。 */
    internal fun showReminder(context: Context, id: String, title: String, due: Long) {
        if (statusMap(context)["notificationsGranted"] != true) {
            Log.w(TAG, "提醒 $id 到点但通知权限未授予，放弃")
            return
        }
        ensureChannel(context)
        val whenText = if (due > 0L) {
            SimpleDateFormat("yyyy-MM-dd", Locale.getDefault()).format(Date(due))
        } else {
            ""
        }
        val body = if (whenText.isEmpty()) {
            title
        } else {
            context.getString(R.string.note_due_prefix, whenText)
        }
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_popup_reminder)
            .setContentTitle(title.ifEmpty { context.getString(R.string.note_reminder_channel) })
            .setContentText(body)
            .setAutoCancel(true)
            .setContentIntent(openAppIntent(context))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .build()
        NotificationManagerCompat.from(context).notify(requestCodeFor(id), notification)
    }

    /**
     * 每日逾期汇总（官方 `TodoNotificationReceiver.notifyOverdue`）：
     * `done = 0 and due_date != -1 and due_date < 今天 00:00`，按 `due_date asc`，
     * 明细 `InboxStyle` 行是 `<可读时间> - <标题>`；没有逾期任务就**不发通知**。
     */
    internal fun showOverdue(context: Context) {
        if (statusMap(context)["notificationsGranted"] != true) {
            Log.w(TAG, "逾期汇总到点但通知权限未授予，放弃")
            return
        }
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val startOfToday = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }.timeInMillis
        val items = ArrayList<OverdueItem>()
        try {
            val arr = JSONArray(prefs.getString(KEY_TODOS, "[]"))
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                if (o.optBoolean("done", false)) continue
                val due = o.optLong("dueDate", -1L)
                if (due <= 0L || due >= startOfToday) continue
                items.add(OverdueItem(o.optString("title"), due))
            }
        } catch (e: Exception) {
            Log.w(TAG, "逾期汇总：快照解析失败", e)
        }
        if (items.isEmpty()) {
            // 官方：没有逾期任务就只打日志、不发通知
            Log.i(TAG, "逾期汇总：没有逾期任务，不发通知")
            return
        }
        items.sortBy { it.due }
        val sdf = SimpleDateFormat("yyyy-MM-dd", Locale.getDefault())
        val style = NotificationCompat.InboxStyle()
        for (item in items.take(5)) {
            style.addLine("${sdf.format(Date(item.due))} - ${item.title}")
        }
        if (items.size > 5) style.setSummaryText("+${items.size - 5}")
        ensureChannel(context)
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_popup_reminder)
            .setContentTitle(context.getString(R.string.note_overdue_title))
            .setContentText(context.getString(R.string.note_overdue_count, items.size))
            .setStyle(style)
            .setAutoCancel(true)
            .setContentIntent(openAppIntent(context))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .build()
        NotificationManagerCompat.from(context).notify(OVERDUE_REQUEST_CODE, notification)
    }

    // ------------------------------------------------------------------ 快照

    private fun loadScheduledIds(context: Context): List<String> {
        val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY_ALARMS, "[]") ?: "[]"
        return try {
            val arr = JSONArray(raw)
            (0 until arr.length()).mapNotNull { arr.optJSONObject(it)?.optString("id") }
        } catch (e: Exception) {
            Log.w(TAG, "闹钟快照解析失败", e)
            emptyList()
        }
    }
}

/** 逾期汇总的一条明细（`<可读时间> - <标题>` 的来源）。 */
private data class OverdueItem(val title: String, val due: Long)

/** 单条待办闹钟的接收者（进程外响铃 → 发通知）。 */
class NoteReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != NoteReminderPlugin.ACTION_REMINDER) return
        val id = intent.getStringExtra(NoteReminderPlugin.EXTRA_ID) ?: return
        val title = intent.getStringExtra(NoteReminderPlugin.EXTRA_TITLE) ?: ""
        val due = intent.getLongExtra(NoteReminderPlugin.EXTRA_DUE, -1L)
        NoteReminderPlugin.showReminder(context, id, title, due)
    }
}

/** 每日逾期汇总的接收者。 */
class NoteReminderOverdueReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != NoteReminderPlugin.ACTION_OVERDUE) return
        NoteReminderPlugin.showOverdue(context)
    }
}

/**
 * 开机 / 应用更新后重排（官方 `AlarmInitReceiver` 同构）。
 *
 * 单独一个 receiver，不动既有 `BootReceiver`（那是 Phase 8 的常驻服务自启）。
 */
class NoteReminderBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != Intent.ACTION_MY_PACKAGE_REPLACED
        ) {
            return
        }
        NoteReminderPlugin.rescheduleFromSnapshot(context)
    }
}
