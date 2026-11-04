// 相册自动备份的**后台执行体**：WorkManager 的 CoroutineWorker。
//
// 依赖边界（硬约束）：本文件只用 `androidx.*` + Android SDK + `io.flutter.*`
//   + `org.json`（本文件未用 JSON）。**没有** FCM、**没有**任何云服务、
//   没有三方库：备份算法**不在原生重写** —— Worker 拉一个 headless
//   `FlutterEngine`，通过 `synhub/photo_backup_bg` 调 Dart 的
//   `runBackup`，由 Dart 复用与前台队列**同一套**上传逻辑（去重/重试/落库）。
//   原生这层只负责：什么时候跑（周期/约束/息屏）、能不能跑（互斥/充电/网络）、
//   跑的时候给用户一个前台通知（dataSync），以及把结果写回 prefs。
//
// 为什么用 CoroutineWorker：`setForeground` 是挂起函数（App 退后台时 WorkManager
//   必须有前台服务通知才不被 ANR/杀），且 Dart 回调需要挂起等待。
//
// 重试有界：`MAX_ATTEMPTS = 3`（`runAttemptCount`），**绝不**无限 retry ——
//   无限退避在"未登录/图库权限被撤"时只会白耗电。
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

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.ForegroundInfo
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkInfo
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.FlutterCallbackInformation
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.util.HashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.resume

class PhotoBackupWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {

    companion object {
        private const val TAG = "SynologyChatPhotoWk"

        /**
         * 官方 `BackupWork.schedulePeriodicWork` 用的就是 **1 小时** 周期。
         * WorkManager 的最小周期是 15 分钟，1 小时在省电与及时性之间是官方取的值。
         */
        const val PERIODIC_HOURS = 1L

        /** 有界重试：同一次运行最多 3 次，之后 failure（避免无限退避耗电）。 */
        private const val MAX_ATTEMPTS = 3

        /** 一次性"立刻跑"的 unique work 后缀（与周期任务区分）。 */
        private const val NOW_SUFFIX = "-now"

        /** 官方相册备份前台服务用的通知 id（10001）。 */
        private const val NOTIFICATION_ID = 10001

        /** 进程内互斥：两个 Worker 实例绝不重叠跑（跨进程由 WorkManager 保证）。 */
        private val running = AtomicBoolean(false)

        private fun constraintsOf(chargeOnly: Boolean, wifiOnly: Boolean): Constraints =
            Constraints.Builder()
                .setRequiresCharging(chargeOnly)
                .setRequiredNetworkType(
                    if (wifiOnly) NetworkType.UNMETERED else NetworkType.CONNECTED,
                )
                .build()

        /**
         * 周期任务 + 立刻入队一次（改设置马上生效）。
         *
         * `ExistingPeriodicWorkPolicy.UPDATE`：保留已有周期任务的身份、只换约束，
         * 不会把 1 小时周期重置成"从现在重新计时"。
         */
        fun schedule(
            context: Context,
            chargeOnly: Boolean,
            screenOffOnly: Boolean,
            wifiOnly: Boolean,
        ) {
            val request = PeriodicWorkRequestBuilder<PhotoBackupWorker>(
                PERIODIC_HOURS,
                TimeUnit.HOURS,
            )
                .setConstraints(constraintsOf(chargeOnly, wifiOnly))
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 60L, TimeUnit.SECONDS)
                .build()
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(
                PhotoBackupPlugin.WORK_NAME,
                ExistingPeriodicWorkPolicy.UPDATE,
                request,
            )
            Log.i(
                TAG,
                "周期任务已排：每 ${PERIODIC_HOURS}h chargeOnly=$chargeOnly " +
                    "wifiOnly=$wifiOnly screenOffOnly=$screenOffOnly",
            )
            enqueueNow(context)
        }

        /** 立刻跑一次（也用于开机恢复 / 息屏触发）。拿到锁 → REPLACE 旧的一次性任务。 */
        fun enqueueNow(context: Context): Boolean = try {
            val request = OneTimeWorkRequestBuilder<PhotoBackupWorker>()
                .setConstraints(currentConstraints(context))
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30L, TimeUnit.SECONDS)
                .build()
            WorkManager.getInstance(context).enqueueUniqueWork(
                PhotoBackupPlugin.WORK_NAME + NOW_SUFFIX,
                ExistingWorkPolicy.REPLACE,
                request,
            )
            Log.i(TAG, "一次性任务已入队")
            true
        } catch (e: Exception) {
            Log.w(TAG, "一次性任务入队失败", e)
            false
        }

        /** 关闭备份：周期任务和一次性任务都撤销。 */
        fun cancel(context: Context) {
            val wm = WorkManager.getInstance(context)
            wm.cancelUniqueWork(PhotoBackupPlugin.WORK_NAME)
            wm.cancelUniqueWork(PhotoBackupPlugin.WORK_NAME + NOW_SUFFIX)
            Log.i(TAG, "已撤销相册备份后台任务")
        }

        /** 周期任务或一次性任务任意一个处于 ENQUEUED/RUNNING 就算"已排程"。 */
        fun isScheduled(context: Context): Boolean =
            isActive(context, PhotoBackupPlugin.WORK_NAME) ||
                isActive(context, PhotoBackupPlugin.WORK_NAME + NOW_SUFFIX)

        private fun isActive(context: Context, name: String): Boolean = try {
            WorkManager.getInstance(context)
                .getWorkInfosForUniqueWork(name)
                .get()
                .any { it.state == WorkInfo.State.ENQUEUED || it.state == WorkInfo.State.RUNNING }
        } catch (e: Exception) {
            // 查询失败（WorkManager 未初始化/数据库未就绪）按"没排"处理，但必须留痕
            Log.w(TAG, "查询 WorkManager 状态失败：$name", e)
            false
        }

        /** 从持久化设置重建约束（Worker 内部重查充电/网络时也用）。 */
        fun currentConstraints(context: Context): Constraints =
            constraintsOf(
                PhotoBackupPlugin.isChargeOnly(context),
                PhotoBackupPlugin.isWifiOnly(context),
            )
    }

    // ------------------------------------------------------------------ 执行

    override suspend fun doWork(): Result {
        val ctx = applicationContext

        // 1) 用户关了备份 → 直接成功（不是失败，避免统计里出现"错误"）。
        if (!PhotoBackupPlugin.isEnabled(ctx)) {
            Log.i(TAG, "备份已关闭，跳过")
            return Result.success()
        }

        // 2) 前台队列正在跑 → 不重复传同一批照片（前台/后台互斥）。
        if (PhotoBackupPlugin.foregroundRunning) {
            Log.i(TAG, "前台正在备份，后台不重复入队/不重复跑")
            return Result.success()
        }

        // 3) 进程内互斥：拿不到锁说明已经有一个 Worker 在跑。
        if (!running.compareAndSet(false, true)) {
            Log.i(TAG, "已有后台备份在跑，跳过本次")
            return Result.success()
        }

        return try {
            // 4) 息屏要求：仅息屏模式下屏幕亮着就退避重试（等下一次窗口）。
            if (PhotoBackupPlugin.isScreenOffOnly(ctx) && isScreenInteractive(ctx)) {
                Log.i(TAG, "仅息屏备份：屏幕亮着，退避重试")
                return Result.retry()
            }

            // 5) 充电要求：WorkManager 约束已经保证，这里显式复查一次，
            //    让行为在日志/状态里可观察（约束判定与执行之间有窗口）。
            if (PhotoBackupPlugin.isChargeOnly(ctx) && !PhotoBackupPlugin.isCharging(ctx)) {
                Log.i(TAG, "仅充电备份：当前未充电，退避重试")
                return Result.retry()
            }

            val handle = PhotoBackupPlugin.getCallbackHandle(ctx)
            if (handle <= 0L) {
                Log.w(TAG, "没有注册后台回调句柄（Dart 未 registerCallback），无法执行")
                PhotoBackupPlugin.saveLastResult(ctx, AppLang.s(ctx, R.string.photo_backup_no_callback))
                return Result.failure()
            }

            // 前台服务通知（dataSync）：跑起来后 App 被切后台也不至于被杀。
            setForeground(createForegroundInfo(AppLang.s(applicationContext, R.string.photo_backup_preparing)))

            val args = HashMap<String, Any>().apply {
                put("destination", PhotoBackupPlugin.getDestination(ctx))
                put("chargeOnly", PhotoBackupPlugin.isChargeOnly(ctx))
                put("screenOffOnly", PhotoBackupPlugin.isScreenOffOnly(ctx))
                put("wifiOnly", PhotoBackupPlugin.isWifiOnly(ctx))
                // 后台 isolate 没有回连插件的通道，设备名要在入参里带过去：
                // Dart 用它在 Drive 侧拼 `/mydrive/PhotoBackup/<device>/`。
                put("device", PhotoBackupPlugin.deviceName())
            }

            val reply = runDartBackup(ctx, handle, args)

            // 用返回的 done/total 刷新通知正文（前台通知不能一直"准备备份…"）。
            val done = (reply["done"] as? Number)?.toInt() ?: 0
            val total = (reply["total"] as? Number)?.toInt() ?: 0
            val progressText = if (total > 0) {
                AppLang.s(applicationContext, R.string.photo_backup_progress, done, total)
            } else {
                AppLang.s(applicationContext, R.string.photo_backup_running)
            }
            setForeground(createForegroundInfo(progressText))

            val ok = reply["ok"] as? Boolean ?: false
            val skipped = (reply["skipped"] as? Number)?.toInt() ?: 0
            val failed = (reply["failed"] as? Number)?.toInt() ?: 0
            val summary = if (done == 0 && total == 0 && skipped == 0 && failed == 0) {
                if (ok) AppLang.s(applicationContext, R.string.state_done)
                else AppLang.s(applicationContext, R.string.state_failed)
            } else {
                "完成 $done / 跳过 $skipped / 失败 $failed"
            }
            PhotoBackupPlugin.saveLastResult(ctx, summary)
            Log.i(TAG, "后台备份结果：ok=$ok $summary")

            if (ok) {
                Result.success()
            } else {
                retryOrFail("Dart 备份返回 ok=false")
            }
        } catch (e: Exception) {
            Log.w(TAG, "后台备份异常", e)
            PhotoBackupPlugin.saveLastResult(ctx, AppLang.s(ctx, R.string.photo_backup_failed_fmt, e.message ?: e.javaClass.simpleName))
            retryOrFail("后台备份异常")
        } finally {
            running.set(false)
        }
    }

    /** 有界重试：前 MAX_ATTEMPTS 次 retry，之后 failure（绝不无限退避）。 */
    private fun retryOrFail(reason: String): Result {
        val attempt = runAttemptCount
        return if (attempt < MAX_ATTEMPTS) {
            Log.i(TAG, "$reason，退避重试（attempt=$attempt/$MAX_ATTEMPTS）")
            Result.retry()
        } else {
            Log.w(TAG, "$reason，已达最大重试次数（$MAX_ATTEMPTS），放弃")
            Result.failure()
        }
    }

    private fun isScreenInteractive(context: Context): Boolean {
        val pm = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
        if (pm == null) {
            Log.w(TAG, "没有 PowerManager，息屏判定按『屏幕亮着』处理")
            return true
        }
        return pm.isInteractive
    }

    // ------------------------------------------------------------------ 后台 Flutter 引擎

    /**
     * 拉起 headless FlutterEngine，执行注册过的 Dart entrypoint，然后通过
     * `BG_CHANNEL` 调 `runBackup` 等结果。
     *
     * 引擎生命周期：**创建即用、finally 必 destroy**（否则每跑一次泄漏一个引擎）。
     */
    @Suppress("DEPRECATION") // FlutterCallbackInformation 在新版 Flutter 里标记废弃但仍在
    private suspend fun runDartBackup(
        context: Context,
        handle: Long,
        args: HashMap<String, Any>,
    ): Map<String, Any> {
        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(context)
        loader.ensureInitializationComplete(context, null)

        val callbackInfo = FlutterCallbackInformation.lookupCallbackInformation(handle)
        if (callbackInfo == null) {
            Log.w(TAG, "找不到 handle=$handle 对应的 Dart entrypoint")
            return emptyMap()
        }

        val engine = withContext(Dispatchers.Main) { FlutterEngine(context) }
        try {
            withContext(Dispatchers.Main) {
                io.flutter.plugins.GeneratedPluginRegistrant.registerWith(engine)
                engine.dartExecutor.executeDartCallback(
                    DartExecutor.DartCallback(
                        context.assets,
                        loader.findAppBundlePath(),
                        callbackInfo,
                    ),
                )
            }
            return invokeBg(engine, args)
        } finally {
            withContext(Dispatchers.Main) { engine.destroy() }
        }
    }

    /** 把 MethodChannel 的异步回调桥成挂起函数（成功/失败都返回一个 Map）。 */
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
            val channel = MethodChannel(engine.dartExecutor.binaryMessenger, PhotoBackupPlugin.BG_CHANNEL)
            channel.invokeMethod("runBackup", args, object : MethodChannel.Result {
                override fun success(result: Any?) {
                    val map = (result as? Map<*, *>)
                        ?.entries
                        ?.filter { it.key is String }
                        ?.associate { it.key as String to (it.value ?: "") }
                        ?: emptyMap()
                    if (cont.isActive) cont.resume(map)
                }

                override fun error(code: String, message: String?, details: Any?) {
                    Log.w(TAG, "后台 Dart 备份报错：$code $message")
                    if (cont.isActive) cont.resume(emptyMap<String, Any>())
                }

                override fun notImplemented() {
                    Log.w(TAG, "后台 Dart 未实现 runBackup")
                    if (cont.isActive) cont.resume(emptyMap<String, Any>())
                }
            })
        } catch (e: Exception) {
            Log.w(TAG, "调用后台 Dart runBackup 失败", e)
            if (cont.isActive) cont.resume(emptyMap<String, Any>())
        }
    }
    }

    // ------------------------------------------------------------------ 通知

    /**
     * `ForegroundInfo` **三参**构造：Android 14+ 要求显式声明前台服务类型，
     * 这里用 `dataSync`（与 manifest 的 `FOREGROUND_SERVICE_DATA_SYNC` 一致）。
     */
    private fun createForegroundInfo(text: String): ForegroundInfo {
        val context = applicationContext
        PhotoBackupPlugin.ensureChannel(context)
        val intent = Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags = flags or PendingIntent.FLAG_IMMUTABLE
        }
        val contentIntent = PendingIntent.getActivity(context, 0, intent, flags)
        val notification = NotificationCompat.Builder(context, PhotoBackupPlugin.CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle(context.getString(R.string.photo_backup_notification_title))
            .setContentText(text)
            .setOngoing(true)
            .setProgress(0, 0, true)
            .setContentIntent(contentIntent)
            .build()
        return ForegroundInfo(
            NOTIFICATION_ID,
            notification,
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
        )
    }
}
