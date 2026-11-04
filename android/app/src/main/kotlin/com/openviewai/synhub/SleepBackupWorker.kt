// ★★ ③Drive 第 222 轮 **D84「休眠备份」60 分钟常驻 worker** 的原生半边。
//
// 官方：休眠备份的提醒检查跑在一个 **60min 周期 / flex 10min** 的常驻任务里。
// 我方（本轮）：用 **WorkManager `PeriodicWorkRequest`** 对齐这两个常量：
//   * `schedule(plan)` —— Dart 侧**调度时算好**的"何时提醒 + 文案"经通道传进来，
//     存进 SharedPreferences，并（幂等地）登记周期任务；
//   * worker 到点后**只做两件事**：判断 `now >= show_at_ms` 就发通知，并记录
//     `last_run_at_ms`。判定逻辑仍然只有 Dart 一份（见 Dart 文件头"分工"）。
//   * **不联网、不读图库、不登录** ⇒ 无需任何网络/充电约束。
//
// 依赖边界：只用 `androidx.*` + Android SDK（与 `PhotoBackupWorker` 一致，
// 无三方库、无 FCM）。
// ★★★ 249 轮**真机实测**发现的真 bug：`FlutterEngine` 的构造 / `executeDartCallback` /
//   `destroy` 都标了 `@UiThread`，而 `CoroutineWorker.doWork` 跑在 `Dispatchers.Default`
//   ⇒ 真机上抛 `RuntimeException: Methods marked with @UiThread must be executed on
//   the main thread`（栈：`FlutterJNI.setPlatformMessageHandler` ← `FlutterEngine.<init>`）。
//   修法：引擎相关三处一律 `withContext(Dispatchers.Main)`；等通道回执仍在原线程。
// ★★★ 249 轮真机实测发现的第二个真 bug：headless 引擎**没注册插件**。
//   只把 `FlutterEngine` 起起来是不够的 —— Dart 侧 `runSync` 一开头要读
//   任务表（`path_provider` 的 documents 目录）、要解 Keystore 封存的凭据
//   （`flutter_secure_storage`）等，这些都走**插件**通道。headless 引擎不注册
//   插件时这些调用抛 `MissingPluginException` ⇒ 通道回执是空 `{}`
//   （真机日志：`SynologyChatDriveWake: 后台同步回执：{}`，而**没有**任何
//   "起后台 Dart 失败"，说明引擎起来了、是 Dart 侧炸的）。
//   修法：引擎建好后在主线程 `GeneratedPluginRegistrant.registerWith(engine)`。
package com.openviewai.synhub

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.view.FlutterCallbackInformation
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlin.coroutines.resume

class SleepBackupWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {

    companion object {
        const val TAG = "SynologyChatSleepWk"
        const val WORK_NAME = "sleep_backup_reminder"
        const val CHANNEL = "synhub/sleep_backup_worker"

        /** ★ 226 轮：后台回 Dart **复算**用的通道（官方同构：worker 里跑真判定） */
        const val BG_CHANNEL = "synhub/sleep_backup_bg"
        const val NOTIFY_CHANNEL_ID = "sleep_backup_reminder"

        /** 官方周期常量（Dart 侧 `sleep_backup_worker.dart` 必须一致）。 */
        const val INTERVAL_MINUTES = 60L
        const val FLEX_MINUTES = 10L

        private const val PREF = "sleep_backup_worker"
        private const val KEY_PLAN = "plan_json"
        private const val KEY_LAST_RUN = "last_run_at_ms"
        private const val KEY_LAST_SHOWN = "last_shown_at_ms"
        private const val KEY_CALLBACK = "dart_callback_handle"

        /** 登记周期任务（同名同策略 ⇒ 幂等，不会堆任务）。 */
        fun schedule(context: Context, planJson: String, callbackHandle: Long) {
            context.getSharedPreferences(PREF, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY_PLAN, planJson)
                .putLong(KEY_CALLBACK, callbackHandle)
                .apply()
            val req = PeriodicWorkRequestBuilder<SleepBackupWorker>(
                INTERVAL_MINUTES, TimeUnit.MINUTES,
                FLEX_MINUTES, TimeUnit.MINUTES,
            ).addTag(TAG).build()
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(
                WORK_NAME,
                // 官方也是"已有就更新"语义（周期常量变了要生效）
                ExistingPeriodicWorkPolicy.UPDATE,
                req,
            )
        }

        fun cancel(context: Context) {
            WorkManager.getInstance(context).cancelUniqueWork(WORK_NAME)
        }

        fun isScheduled(context: Context): Boolean =
            WorkManager.getInstance(context)
                .getWorkInfosForUniqueWork(WORK_NAME)
                .get()
                .any { !it.state.isFinished }

        /**
         * 界面侧一条命令登记：`synhub/sleep_backup_worker`
         *   * `schedule {interval_minutes, flex_minutes, plan}` → Bool
         *   * `cancel` → Bool
         *   * `isScheduled` → Bool
         * 传进来的 interval/flex 只做**一致性校验**（不等于官方常量就拒绝登记，
         * 免得 Dart 改了常量而原生没收口）。
         */
        fun attach(messenger: BinaryMessenger, context: Context) {
            MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
                when (call.method) {
                    "schedule" -> {
                        val interval = (call.argument<Number>("interval_minutes") ?: -1).toLong()
                        val flex = (call.argument<Number>("flex_minutes") ?: -1).toLong()
                        val plan = call.argument<String>("plan") ?: ""
                        val callback = (call.argument<Number>("callback") ?: 0L).toLong()
                        if (interval != INTERVAL_MINUTES || flex != FLEX_MINUTES) {
                            result.error(
                                "bad_interval",
                                "周期常量不一致：收到 ${interval}min/flex ${flex}min，" +
                                    "原生要求 ${INTERVAL_MINUTES}/${FLEX_MINUTES}",
                                null,
                            )
                        } else if (plan.isEmpty()) {
                            result.error("bad_plan", "plan 为空", null)
                        } else {
                            schedule(context, plan, callback)
                            result.success(true)
                        }
                    }
                    "cancel" -> { cancel(context); result.success(true) }
                    "isScheduled" -> result.success(isScheduled(context))
                    else -> result.notImplemented()
                }
            }
        }
    }

    override suspend fun doWork(): Result {
        val sp = applicationContext.getSharedPreferences(PREF, Context.MODE_PRIVATE)
        val raw = sp.getString(KEY_PLAN, null)
        val now = System.currentTimeMillis()
        sp.edit().putLong(KEY_LAST_RUN, now).apply()
        // ★ 250 轮：222/226 轮这个 worker **一条日志都没有** ⇒ 真机上"到底跑没跑、
        // Dart 复算有没有回"完全无从取证（249 轮就卡在这）。补上，与
        // `DriveWatchWorker` 的「后台唤醒记账/后台同步回执」同一口径。
        Log.i(TAG, "周期任务被调度：last_run_at_ms=$now")
        if (raw.isNullOrEmpty()) {
            Log.i(TAG, "没有计划 ⇒ 本次什么都不做")
            return Result.success()  // 没有计划 ⇒ 什么都不做
        }
        val plan = try {
            JSONObject(raw)
        } catch (e: Exception) {
            return Result.success()  // 坏数据不无限重试（官方也不在这里退避）
        }
        // ★ 226 轮：**优先回 Dart 复算**（用前台同一套判定重新判一次），
        // 拿不到 Dart（没注册 handle / 引擎起不来）才退回调度时算好的计划。
        val handle = sp.getLong(KEY_CALLBACK, 0L)
        var showNow = false
        var title = plan.optString("title", "")
        var text = plan.optString("text", "")
        if (handle != 0L) {
            val fresh = runDartCheck(handle, plan)
            Log.i(TAG, "后台复算回执：$fresh")
            if (fresh["ok"] == true) {
                showNow = fresh["show"] == true
                title = (fresh["title"] as? String) ?: title
                text = (fresh["text"] as? String) ?: text
                val nextShow = (fresh["next_show_at_ms"] as? Number)?.toLong() ?: 0L
                val backoff = (fresh["backoff_ms"] as? Number)?.toLong() ?: 0L
                val updated = JSONObject(plan.toString())
                updated.put("next_show_at_ms", nextShow)
                updated.put("backoff_ms", backoff)
                sp.edit().putString(KEY_PLAN, updated.toString()).apply()
            } else {
                // Dart 报错 ⇒ 退回旧计划（不做二次判定，宁可这次不发也不发假提醒）
                showNow = now >= plan.optLong("show_at_ms", 0L)
            }
        } else {
            showNow = now >= plan.optLong("show_at_ms", 0L)
        }
        if (!showNow) {
            Log.i(TAG, "本次不发提醒（show=false）")
            return Result.success()
        }
        if (title.isEmpty() && text.isEmpty()) return Result.success()
        Log.i(TAG, "发出休眠备份提醒：$title")
        show(now, title, text)
        sp.edit().putLong(KEY_LAST_SHOWN, now).apply()
        return Result.success()
    }

    /** 起 headless 引擎 → 通道 `check` → 取回判定结果（失败回空 map）。 */
    private suspend fun runDartCheck(
        handle: Long,
        stalePlan: JSONObject,
    ): Map<String, Any> {
        return try {
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(applicationContext)
            loader.ensureInitializationComplete(applicationContext, null)
            val info = FlutterCallbackInformation.lookupCallbackInformation(handle)
                ?: return emptyMap()
            val engine = withContext(Dispatchers.Main) {
                FlutterEngine(applicationContext)
            }
            try {
                withContext(Dispatchers.Main) {
                    io.flutter.plugins.GeneratedPluginRegistrant.registerWith(engine)
                    engine.dartExecutor.executeDartCallback(
                        DartExecutor.DartCallback(
                            applicationContext.assets,
                            loader.findAppBundlePath(),
                            info,
                        ),
                    )
                }
                val args = HashMap<String, Any>()
                args["queue_size"] = stalePlan.optInt("queue_size", 0)
                args["processing"] = stalePlan.optBoolean("processing", false)
                args["title"] = stalePlan.optString("title", "")
                args["text"] = stalePlan.optString("text", "")
                invokeBg(engine, args)
            } finally {
                withContext(Dispatchers.Main) { engine.destroy() }
            }
        } catch (e: Exception) {
            // 后台 Dart 起不来（模型/资源缺失）⇒ 如实返回空，调用方退回旧计划
            emptyMap()
        }
    }

    private suspend fun invokeBg(
        engine: FlutterEngine,
        args: HashMap<String, Any>,
        // ★★★ 249 轮真机实测：`MethodChannel.invokeMethod` 标了 `@UiThread`，
        // 在工作线程（`CoroutineWorker` 的默认调度器）上调用会抛
        // `Methods marked with @UiThread must be executed on the main thread`
        // ⇒ 发起调用必须在主线程（等回执是挂起，不阻塞主线程）。
    ): Map<String, Any> = withContext(Dispatchers.Main) {
        suspendCancellableCoroutine { cont ->
        try {
            val channel = MethodChannel(engine.dartExecutor.binaryMessenger, BG_CHANNEL)
            channel.invokeMethod("check", args, object : MethodChannel.Result {
                override fun success(result: Any?) {
                    val map = (result as? Map<*, *>)
                        ?.entries
                        ?.filter { it.key is String }
                        ?.associate { it.key as String to (it.value ?: "") }
                        ?: emptyMap()
                    if (cont.isActive) cont.resume(map)
                }

                override fun error(code: String, message: String?, details: Any?) {
                    if (cont.isActive) cont.resume(emptyMap<String, Any>())
                }

                override fun notImplemented() {
                    if (cont.isActive) cont.resume(emptyMap<String, Any>())
                }
            })
        } catch (e: Exception) {
            if (cont.isActive) cont.resume(emptyMap<String, Any>())
        }
    }
    }

    private fun show(nowMs: Long, title: String, text: String) {
        val ctx = applicationContext
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            nm.getNotificationChannel(NOTIFY_CHANNEL_ID) == null
        ) {
            nm.createNotificationChannel(
                NotificationChannel(
                    NOTIFY_CHANNEL_ID,
                    AppLang.s(ctx, R.string.sleep_backup_channel),
                    NotificationManager.IMPORTANCE_DEFAULT,
                )
            )
        }
        val intent = Intent(ctx, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pi = PendingIntent.getActivity(
            ctx,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val n = NotificationCompat.Builder(ctx, NOTIFY_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle(title)
            .setContentText(text)
            .setAutoCancel(true)
            .setContentIntent(pi)
            .build()
        try {
            nm.notify(NOTIFY_ID, n)
        } catch (e: SecurityException) {
            // 没给 POST_NOTIFICATIONS 就静默跳过（官方同样受这个权限约束）
        }
    }
}

/** 通知 id：固定值 ⇒ 多次触发只更新同一条，不刷屏。 */
private const val NOTIFY_ID = 4330
