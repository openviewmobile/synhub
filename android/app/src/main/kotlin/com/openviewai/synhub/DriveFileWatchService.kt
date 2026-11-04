// ★★★ ③Drive 第 228 轮 **D65「App 被杀后仍常驻监听」的原生半边**。
//
// ## 官方对照
// 官方 Drive 安卓端有一个常驻 `DriveFileWatchService`：用 `FileObserver` 盯着
// 同步目录，变化了就唤醒同步（App 不在前台也生效）。
//
// ## 本文件做什么
//   * 前台通过通道 `synhub/drive_watch` 把"要盯的本地根"交进来；
//   * 本 Service 为每个根（以及其子目录，深度 `MAX_DEPTH`）注册 `FileObserver`
//     —— Android 的 `FileObserver` **不递归**，所以子目录要自己走；
//   * 事件到达后**去抖** `DEBOUNCE_SECONDS` 秒，再排一个 `DriveWatchWorker`
//     一次性任务（引擎里回 Dart 记账 + 唤醒）；
//   * Service 是 `START_STICKY`，被系统杀掉后重启会**从 SharedPreferences 读回**
//     根列表继续盯（这就是"App 被杀仍常驻"的关键）。
//
// ## 诚实边界
// 后台只做"**看 + 唤醒 + 记账**"，真正的文件搬运回到前台才做（原因见 Dart 侧
// `drive_watch_bridge.dart` 的头注释：后台驱动器要整条静默重登链路，
// Drive 侧还没做那一轮，也不假装做到）。
package com.openviewai.synhub

import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.FileObserver
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import java.io.File
import java.util.concurrent.ConcurrentHashMap

class DriveFileWatchService : Service() {

    companion object {
        private const val TAG = "SynologyChatDriveWatch"
        const val PREF = "drive_file_watch"
        const val KEY_ROOTS = "roots"
        const val DEBOUNCE_SECONDS = 3L
        const val MAX_DEPTH = 2

        /**
         * 登记要盯的根并启动 Service。
         *
         * 返回 **false** 表示系统拒绝了启动（此时 prefs 已回滚，`isRunning()` 仍是 false）。
         *
         * ★ 249 轮**真机实测**发现：Android 12+（API 31）**不在前台时**不允许
         * `startService`，会抛 `BackgroundServiceStartNotAllowedException`
         * （`IllegalStateException` 的子类）。真机取证时就撞到过（设备息屏 ⇒
         * 集成测试进程被系统判为 `cached`）：
         *
         * ```
         * BackgroundServiceStartNotAllowedException: Not allowed to start service Intent
         *   { cmp=com.openviewai.synhub/.DriveFileWatchService }: app is in background
         * ```
         *
         * ⇒ 这里**如实回滚 + 返回 false**，不留下"prefs 说在盯、其实没在盯"的假状态；
         * Dart 侧把 false 变成一句给用户看的实话（而不是抛异常炸掉）。
         * 仍然用 `startService`（不是 `startForegroundService`）：本 Service 只注册
         * FileObserver、**不需要**常驻通知；官方也是从**前台界面**开启监听的。
         */
        fun start(context: Context, roots: List<String>): Boolean {
            context.getSharedPreferences(PREF, Context.MODE_PRIVATE)
                .edit()
                .putStringSet(KEY_ROOTS, roots.toSet())
                .apply()
            return try {
                context.startService(Intent(context, DriveFileWatchService::class.java))
                true
            } catch (e: IllegalStateException) {
                Log.w(TAG, "系统不允许此时启动常驻监听（App 不在前台？）：${e.message}")
                context.getSharedPreferences(PREF, Context.MODE_PRIVATE)
                    .edit().remove(KEY_ROOTS).apply()
                false
            }
        }

        fun stop(context: Context) {
            context.getSharedPreferences(PREF, Context.MODE_PRIVATE)
                .edit().remove(KEY_ROOTS).apply()
            context.stopService(Intent(context, DriveFileWatchService::class.java))
        }

        fun isRunning(context: Context): Boolean =
            !context.getSharedPreferences(PREF, Context.MODE_PRIVATE)
                .getStringSet(KEY_ROOTS, emptySet())!!.isEmpty()
    }

    private val observers = ConcurrentHashMap<String, FileObserver>()
    private val handler = Handler(Looper.getMainLooper())
    private var pendingWake: Runnable? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val roots = sharedPreferences().getStringSet(KEY_ROOTS, emptySet()) ?: emptySet()
        attachObservers(roots.toList())
        // ⚠️ `START_STICKY`：被系统回收后重启，会再走一遍 onStartCommand 把
        // prefs 里的根重新挂上 —— 这就是"App 被杀仍在盯"的实现方式。
        return START_STICKY
    }

    override fun onDestroy() {
        detachObservers()
        super.onDestroy()
    }

    private fun sharedPreferences() =
        getSharedPreferences(PREF, Context.MODE_PRIVATE)

    private fun attachObservers(roots: List<String>) {
        detachObservers()
        for (root in roots) {
            val dir = File(root)
            if (!dir.isDirectory) {
                Log.w(TAG, "跳过不存在的根：$root")
                continue
            }
            watchRecursive(dir, 0)
        }
        Log.i(TAG, "已挂 ${observers.size} 个 FileObserver")
    }

    /** `FileObserver` 不递归 ⇒ 自己按 `MAX_DEPTH` 走子目录 */
    private fun watchRecursive(dir: File, depth: Int) {
        if (observers.size > 200) return  // 防御：别把 fd 用光
        val mask = FileObserver.CREATE or
            FileObserver.MODIFY or
            FileObserver.DELETE or
            FileObserver.MOVED_FROM or
            FileObserver.MOVED_TO
        val obs = object : FileObserver(dir.absolutePath, mask) {
            override fun onEvent(event: Int, path: String?) {
                scheduleWake()
            }
        }
        obs.startWatching()
        observers[dir.absolutePath] = obs
        if (depth >= MAX_DEPTH) return
        dir.listFiles()?.filter { it.isDirectory }?.forEach { watchRecursive(it, depth + 1) }
    }

    private fun detachObservers() {
        for (o in observers.values) {
            try {
                o.stopWatching()
            } catch (_: Exception) {
            }
        }
        observers.clear()
    }

    /** 去抖：窗口内只排一次唤醒（编辑器保存通常连发好几个事件）。 */
    private fun scheduleWake() {
        pendingWake?.let { handler.removeCallbacks(it) }
        val r = Runnable {
            val roots = sharedPreferences()
                .getStringSet(KEY_ROOTS, emptySet()) ?: emptySet()
            if (roots.isEmpty()) return@Runnable
            DriveWatchWorker.enqueue(applicationContext, roots.toList())
        }
        pendingWake = r
        handler.postDelayed(r, DEBOUNCE_SECONDS * 1000)
    }
}
