package com.openviewai.synhub

import android.content.Context
import android.util.Log
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.workDataOf
import java.util.concurrent.TimeUnit

/**
 * 笔记后台同步的**排程**（第 114 轮 M3）。
 *
 * 官方对应物是 `Utils.resumeSyncService/pauseSyncService`（启停常驻
 * `dataSync` 服务）；我方用 WorkManager 周期任务实现同一目的，
 * 并保留同样的"用户可开关"语义（[enable] / [disable]）。
 *
 * * 周期：**15 分钟**（WorkManager 的周期下限；官方是常驻服务，
 *   这里受平台约束取最小可用值 —— 已在文档登记为机制等价）；
 * * 唯一任务名 `note-sync-periodic`（`KEEP`：重复调用不会重置周期）；
 * * 约束：需要网络（`CONNECTED`）。
 */
object NoteSyncScheduler {

    const val TAG = "NoteSyncScheduler"
    const val PREF = "synhub_note_sync"
    const val KEY_ENABLED = "enabled"
    const val KEY_CALLBACK_HANDLE = "callback_handle"
    const val UNIQUE_PERIODIC = "note-sync-periodic"
    const val UNIQUE_ONESHOT = "note-sync-now"

    /** 本模块自己的 SharedPreferences（**不**蹭 BackgroundBridge 的键空间）。 */
    fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREF, Context.MODE_PRIVATE)

    private val constraints = Constraints.Builder()
        .setRequiredNetworkType(NetworkType.CONNECTED)
        .build()

    /** 记录 Dart entrypoint handle（前台启动时登记一次）。 */
    fun registerCallback(context: Context, handle: Long) {
        prefs(context).edit()
            .putLong(KEY_CALLBACK_HANDLE, handle)
            .apply()
    }

    fun isEnabled(context: Context): Boolean =
        prefs(context).getBoolean(KEY_ENABLED, true)

    /** 打开后台同步并排上周期任务（幂等）。 */
    fun enable(context: Context) {
        val app = context.applicationContext
        prefs(app).edit().putBoolean(KEY_ENABLED, true).apply()
        schedulePeriodic(app)
    }

    /** 关掉后台同步并取消任务（**不影响**已同步数据）。 */
    fun disable(context: Context) {
        val app = context.applicationContext
        prefs(app).edit().putBoolean(KEY_ENABLED, false).apply()
        WorkManager.getInstance(app).cancelUniqueWork(UNIQUE_PERIODIC)
    }

    /** 立刻同步一次（前台"立即同步"按钮 / 开机后的补跑）。 */
    fun syncNow(context: Context, reason: String) {
        val app = context.applicationContext
        val request = OneTimeWorkRequestBuilder<NoteSyncWorker>()
            .setConstraints(constraints)
            .setInputData(workDataOf(NoteSyncWorker.KEY_REASON to reason))
            .build()
        WorkManager.getInstance(app)
            .enqueueUniqueWork(UNIQUE_ONESHOT, androidx.work.ExistingWorkPolicy.REPLACE, request)
    }

    /** 开机/升级后补排（`BootReceiver` 调；用户关过就不排）。 */
    fun rescheduleIfEnabled(context: Context) {
        if (isEnabled(context)) {
            schedulePeriodic(context.applicationContext)
        } else {
            Log.i(TAG, "用户已关闭后台同步，开机不排")
        }
    }

    private fun schedulePeriodic(app: Context) {
        val request = PeriodicWorkRequestBuilder<NoteSyncWorker>(15, TimeUnit.MINUTES)
            .setConstraints(constraints)
            .setInputData(workDataOf(NoteSyncWorker.KEY_REASON to "periodic"))
            .build()
        WorkManager.getInstance(app).enqueueUniquePeriodicWork(
            UNIQUE_PERIODIC,
            ExistingPeriodicWorkPolicy.KEEP,
            request,
        )
    }
}
