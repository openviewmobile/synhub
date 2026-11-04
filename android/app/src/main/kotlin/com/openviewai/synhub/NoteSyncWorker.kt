// 笔记后台同步的 WorkManager Worker（第 114 轮 M3）。
//
// 官方 DSnote 用**常驻 `dataSync` 前台服务**（`SyncService`，
// `AndroidManifest.xml:113`）+ `Utils.resumeSyncService/pauseSyncService`
// 由界面驱动启停；WorkManager 在官方包里**只**服务全文索引
// （`FullTextSearchWorker`，无 PeriodicWorkRequest）。
//
// 我方不常驻服务（本机 Android 后台限制 + 与聊天 socket 服务区分），
// 改用 **WorkManager 周期任务**达到同一效果：定时唤醒 → headless
// FlutterEngine → Dart `noteBackgroundSyncMain` → 复用同一个 NoteSync。
// 这是**机制等价**（目标一致、手段按平台约束替换），已在文档里登记。
//
// 约束（与照片备份同口径）：需要网络；不要求充电（笔记是小流量文本同步）。
package com.openviewai.synhub

import android.content.Context
import android.util.Log
import androidx.work.CoroutineWorker
import androidx.work.NetworkType
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.embedding.engine.loader.FlutterLoader
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.FlutterCallbackInformation
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class NoteSyncWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        val reason = inputData.getString(KEY_REASON) ?: "workmanager"
        val store = NoteSyncScheduler.prefs(applicationContext)
        val handle = store.getLong(NoteSyncScheduler.KEY_CALLBACK_HANDLE, 0L)
        if (handle == 0L) {
            // 还没登记 Dart entrypoint（用户没打开过 App）⇒ 不算失败，
            // 等下次（登记是前台启动时做的）
            Log.i(TAG, "未登记 callback handle，跳过（reason=$reason）")
            return@withContext Result.success(workDataOf("skipped" to "no-handle"))
        }
        try {
            val report = runDartSync(handle, reason)
            Log.i(TAG, "后台同步完成：$report")
            Result.success(workDataOf("report" to report))
        } catch (t: Throwable) {
            Log.w(TAG, "后台同步失败：${t.message}")
            if (runAttemptCount < 3) Result.retry() else Result.failure()
        }
    }

    /** 起 headless 引擎跑一轮同步，`CountDownLatch` 等结果（同照片备份口径）。 */
    private suspend fun runDartSync(handle: Long, reason: String): String {
        val context = applicationContext
        val callbackInfo = FlutterCallbackInformation.lookupCallbackInformation(handle)
            ?: throw IllegalStateException("找不到 handle=$handle 的 entrypoint")
        val loader = FlutterLoader()
        loader.startInitialization(context)
        loader.ensureInitializationComplete(context, null)
        val engine = FlutterEngine(context)
        val latch = CountDownLatch(1)
        var payload = "{}"
        engine.dartExecutor.executeDartCallback(
            DartExecutor.DartCallback(context.assets, loader.findAppBundlePath(), callbackInfo)
        )
        val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        channel.invokeMethod(
            "runSync",
            mapOf("reason" to reason),
            object : MethodChannel.Result {
                override fun success(result: Any?) {
                    payload = result?.toString() ?: "{}"
                    latch.countDown()
                }

                override fun error(code: String, message: String?, details: Any?) {
                    payload = "{\"ok\":false,\"error\":\"$code\"}"
                    latch.countDown()
                }

                override fun notImplemented() {
                    payload = "{\"ok\":false,\"error\":\"not-implemented\"}"
                    latch.countDown()
                }
            },
        )
        latch.await(90, TimeUnit.SECONDS)
        engine.destroy()
        return payload
    }

    companion object {
        const val TAG = "NoteSyncWorker"
        const val CHANNEL = "synhub/note_sync_bg"
        const val KEY_REASON = "reason"
    }
}
