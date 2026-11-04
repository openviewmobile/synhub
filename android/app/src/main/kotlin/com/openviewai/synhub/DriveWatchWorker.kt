// ★★★ ③Drive 第 228 轮 **D65 原生监听的唤醒执行体**。
//
// 由 `DriveFileWatchService`（`FileObserver` 去抖后）排一个**一次性** WorkManager 任务：
//   * 起 headless `FlutterEngine`（与 `PhotoBackupWorker` / `SleepBackupWorker` 同构）；
//   * 通道 `synhub/drive_watch_bg` 依次调两个方法：
//       `wake    {task_ids: [<本地根>]}` —— 记账（228 轮语义，保留）；
//       `runSync {task_ids: [<本地根>]}` —— ★ 248 轮：**真的跑一轮同步**
//       （静默重登 → 拉远端 → 计划差异 → 上传/下载/删除 → 回执）。
//
// ★ 248 轮把"只记账"补成了"真的搬文件"（官方 `SyncRunner` 的后台等价物）。
// ⚠️ headless 引擎**必须自己挂 `KeystoreBridge`**：静默重登要用上次登录的密码，
// 而那份密码是 Keystore 封存的 —— 主界面那套 `configureFlutterEngine` 注册的
// 自定义通道在 headless 引擎里**不存在**（这是 248 轮修的一个真问题：
// 不挂的话后台永远只能拿到"凭据解不开"）。
// 因此本 worker **不需要** `setForeground`（不长时间占用），也就**不需要**在
// manifest 里声明前台服务类型。
// ★★★ 249 轮**真机实测**发现的真 bug（`DriveWatchWorker.kt:95` 的原始报错）：
//   `FlutterEngine` 的构造 / `executeDartCallback` / `destroy` 都标了 `@UiThread`，
//   而 `CoroutineWorker.doWork` 跑在 `Dispatchers.Default` ⇒ 真机上抛
//   `java.lang.RuntimeException: Methods marked with @UiThread must be executed on
//    the main thread. Current thread: DefaultDispatcher-worker-3`
//   （栈：`FlutterJNI.setPlatformMessageHandler` ← `FlutterEngine.<init>`）。
//   ⇒ 三个后台 worker（Drive 唤醒 / 相册备份 / 休眠备份）**在真机上从来没起来过**。
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

import android.content.Context
import android.util.Log
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.FlutterCallbackInformation
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.util.HashMap
import kotlin.coroutines.resume

class DriveWatchWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {

    companion object {
        /** Dart 侧 handler 就绪重试次数 / 间隔（合计 5s，够 headless 引擎冷启动）。 */
        private const val READY_RETRY = 20
        private const val READY_DELAY_MS = 250L

        private const val TAG = "SynologyChatDriveWake"
        const val WORK_NAME = "drive_file_watch_wake"
        const val BG_CHANNEL = "synhub/drive_watch_bg"
        const val KEY_CALLBACK = "dart_callback_handle"

        /**
         * 排一次唤醒（`REPLACE` 语义：去抖窗口内多次触发只留最后一次）。
         *
         * `task_ids` 这里放的就是**本地根路径** —— 原生不知道 Dart 侧的任务 id，
         * 由 Dart 后台入口把"根 → 任务"的映射做掉（`drive_watch_bridge.dart`）。
         */
        fun enqueue(context: Context, roots: List<String>) {
            val req = OneTimeWorkRequestBuilder<DriveWatchWorker>()
                .setInputData(workDataOf("task_ids" to roots.toTypedArray()))
                .addTag(TAG)
                .build()
            WorkManager.getInstance(context).enqueueUniqueWork(
                WORK_NAME,
                ExistingWorkPolicy.REPLACE,
                req,
            )
        }

        /** `PluginUtilities.getCallbackHandle(driveWatchBackgroundMain)` 的落点 */
        fun rememberCallbackHandle(context: Context, handle: Long) {
            context.getSharedPreferences(DriveFileWatchService.PREF, Context.MODE_PRIVATE)
                .edit().putLong(KEY_CALLBACK, handle).apply()
        }
    }

    override suspend fun doWork(): Result {
        val roots = inputData.getStringArray("task_ids")?.toList() ?: emptyList()
        if (roots.isEmpty()) return Result.success()
        val handle = applicationContext
            .getSharedPreferences(DriveFileWatchService.PREF, Context.MODE_PRIVATE)
            .getLong(KEY_CALLBACK, 0L)
        if (handle == 0L) {
            Log.w(TAG, "没有 Dart callback handle ⇒ 无法记账（前台还没登记过回调）")
            return Result.success()
        }
        val report = runDartWake(handle, roots)
        Log.i(TAG, "后台唤醒记账：$report")
        // 记账失败**不重试**：重试也解决不了"回调没注册/引擎起不来"，只会白耗电
        return Result.success()
    }

    private suspend fun runDartWake(handle: Long, roots: List<String>): Map<String, Any> {
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
                    // ★ 249 轮：headless 引擎必须注册**全部**插件（见文件头说明），
                    // 否则 Dart 侧读任务表/解凭据全抛 MissingPluginException。
                    io.flutter.plugins.GeneratedPluginRegistrant.registerWith(engine)
                    // ★ 248 轮：headless 引擎也要能解 Keystore 封存的凭据，
                    // 否则后台静默重登永远失败（见文件头说明）。
                    KeystoreBridge.attach(engine)
                    engine.dartExecutor.executeDartCallback(
                        DartExecutor.DartCallback(
                            applicationContext.assets,
                            loader.findAppBundlePath(),
                            info,
                        ),
                    )
                }
                val args = HashMap<String, Any>()
                args["task_ids"] = ArrayList(roots)
                // ① 记账（228 轮语义）
                invokeBg(engine, args, "wake")
                // ② ★ 248 轮：真的跑一轮同步；回执记进 WorkManager 输出便于排障
                val sync = invokeBg(engine, args, "runSync")
                Log.i(TAG, "后台同步回执：$sync")
                // 显式作为 try 的返回值：上一句 Log.i 返回 Int，不写这一行
                // 整个 try 表达式会推断成 Any（编译报过
                // `Return type mismatch: expected Map<String, Any>, actual Any`）
                sync
            } finally {
                withContext(Dispatchers.Main) { engine.destroy() }
            }
        } catch (e: Exception) {
            Log.w(TAG, "起后台 Dart 失败", e)
            emptyMap()
        }
    }

    /**
     * 调一次 Dart 侧通道。
     *
     * ★★★ 249 轮真机实测的第三个坑：`executeDartCallback` 是**异步**的 ——
     * 引擎起来 ≠ Dart 侧 `setMethodCallHandler` 已经执行完。228 轮写的"起完引擎
     * 立刻调通道"在真机上就是抢跑：Dart 侧还没挂 handler ⇒ `notImplemented`
     * ⇒ 回执空 `{}`（真机日志：`后台同步回执：{}`，而引擎**没有**报错）。
     * 修法：只在"handler 还没挂上"（`notImplemented` / `MissingPluginException`）
     * 时**重试**，最多 [READY_RETRY] × [READY_DELAY_MS]；
     * 一旦 Dart 侧真的回了 `error(...)`，说明 handler 已在、是**业务**错误 ——
     * 这时**绝不重试**（`runSync` 重跑可能重复上传/删除），如实记日志返回空。
     */
    private suspend fun invokeBg(
        engine: FlutterEngine,
        args: HashMap<String, Any>,
        method: String,
    ): Map<String, Any> {
        repeat(READY_RETRY) { attempt ->
            val channel = MethodChannel(engine.dartExecutor.binaryMessenger, BG_CHANNEL)
            // ★★★ 249 轮真机实测的第四个坑：`MethodChannel.invokeMethod` 也标了
            // `@UiThread`（走 `DartMessenger` → `FlutterJNI`）—— 在工作线程上调用会抛
            // `Methods marked with @UiThread must be executed on the main thread.
            //  Current thread: DefaultDispatcher-worker-1`（真机日志抓到的原话）。
            // 所以**发起调用**必须在主线程；等回执是挂起，不阻塞主线程。
            val outcome = withContext(Dispatchers.Main) {
                suspendCancellableCoroutine { cont ->
                try {
                    channel.invokeMethod(method, args, object : MethodChannel.Result {
                        override fun success(result: Any?) {
                            val map = (result as? Map<*, *>)
                                ?.entries
                                ?.filter { it.key is String }
                                ?.associate { it.key as String to (it.value ?: "") }
                                ?: emptyMap()
                            if (cont.isActive) cont.resume(BgOutcome.Done(map))
                        }

                        override fun error(code: String, message: String?, details: Any?) {
                            Log.w(TAG, "通道 $method 报错：$code $message")
                            if (cont.isActive) cont.resume(BgOutcome.Done(emptyMap()))
                        }

                        override fun notImplemented() {
                            if (cont.isActive) cont.resume(BgOutcome.NotReady())
                        }
                    })
                } catch (e: Exception) {
                    Log.w(TAG, "通道 $method 调用异常（第 ${attempt + 1} 次）：${e.message}")
                    if (cont.isActive) cont.resume(BgOutcome.NotReady())
                    }
                }
            }
            if (outcome is BgOutcome.Done) return outcome.map
            delay(READY_DELAY_MS)
        }
        Log.w(TAG, "通道 $method 等了 ${READY_RETRY * READY_DELAY_MS}ms，Dart 侧仍未挂上 handler")
        return emptyMap()
    }

    private sealed interface BgOutcome {
        /** Dart 侧已应答（含业务错误 ⇒ 空 map）。 */
        data class Done(val map: Map<String, Any>) : BgOutcome

        /** Dart 侧还没挂 handler / 引擎还没就绪。 */
        class NotReady : BgOutcome
    }
}
