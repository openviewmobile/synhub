// Phase 8：常驻 Socket 的前台 Service。
//
// 作用：App 退到后台时不让系统回收进程（Dart 侧的 socket 才活得下来）。
// Dart 侧在「已登录 + socket 连上」时 start，登出时 stop。
//
// 注意：这是**保活**方案，不是纯原生推送——App 被用户在最近任务里划掉、
// 或被 OEM 省电策略强杀时，进程没了就没有通知（原 App 靠 FCM 才免于此，
// 我们复用不了它的 Firebase 项目，计划里 §4.4 已接受这个代价）。
//
// ★ 第 278 轮：前台服务类型由 `dataSync` 改为 **`specialUse`**，并补
// `onTimeout` 兜底。理由逐条（官方 behavior-changes-15 原文，
// 完整矩阵见 `docs/android-compat-matrix.md` §1）：
//
//   ① **dataSync 有 24h/6h 上限**：以 Android 15（API 35）为目标平台时，
//      "系统允许应用的 dataSync 服务在 24 小时内总共运行 6 小时，之后系统会调用
//      正在运行的服务的 `Service.onTimeout(int, int)` 方法"；几秒内不
//      `stopSelf()` 就抛
//      `RemoteServiceException: A foreground service of type dataSync did not
//       stop within its timeout`。常驻 Socket 是**长期**的 ⇒ 必然撞上。
//   ② **BOOT_COMPLETED 不许拉起 dataSync**：Android 15 起
//      "BOOT_COMPLETED receivers are not allowed to launch the following types of
//       foreground services: dataSync / camera / mediaPlayback / phoneCall /
//       mediaProjection / microphone"，否则抛
//      `ForegroundServiceStartNotAllowedException` —— `.BootReceiver` 正是开机
//      拉起本服务。
//   ③ `specialUse` 是"其它类型都不贴切"时的**官方兜底类型**，且**不在**上面
//      两条的限制名单里。它要求：manifest 上
//      `android:foregroundServiceType="specialUse"` + `<property
//      android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE"/>` +
//      `FOREGROUND_SERVICE_SPECIAL_USE` 普通权限（三样都在 manifest 里）。
//
// `onTimeout` 仍然实现：`specialUse` 今天没有超时，但
//   * 实现它是**零成本**的防御（万一类型回退/被 ROM 改写，不会变成"闪退"）；
//   * 语义正确 —— 超时就**如实停止前台并让 Dart 侧重连**，不装死。
//
// `startForeground` 继续用 **2 参数**重载：平台按 manifest 里声明的类型走
// （显式传 type 在某些 ROM 上会因"请求类型不是 manifest 类型的子集"抛
// `IllegalArgumentException`，2 参数是官方推荐的安全写法）。
package com.openviewai.synhub

import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationManagerCompat

class ChatForegroundService : Service() {
    companion object {
        const val NOTIFICATION_ID = 1001
        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"
        private const val TAG = "SynologyChatFgs"

        /** Dart 侧问「服务在跑吗」（集成测试也会用） */
        @Volatile
        var running: Boolean = false
            private set

        /**
         * 最近一次"前台服务没能起来"的原因（空串 = 没有失败）。
         *
         * 为什么要暴露它：Android 12+ 后台启动前台服务会抛
         * `ForegroundServiceStartNotAllowedException`（Android 15 起
         * BOOT_COMPLETED 拉 dataSync 也会抛），这是**正常可预期的失败**，
         * 不能吞掉、更不能崩 —— Dart 侧据此提示"后台保活未生效"。
         */
        @Volatile
        var lastStartError: String = ""
            private set

        /**
         * 启动常驻服务；**不抛**。
         *
         * @return true = 系统接受了这次启动请求（不代表 1 秒后还活着）；
         *         false = 被系统拒绝（原因进 [lastStartError]）。
         */
        fun start(context: Context, title: String, text: String): Boolean {
            val intent = Intent(context, ChatForegroundService::class.java)
                .putExtra(EXTRA_TITLE, title)
                .putExtra(EXTRA_TEXT, text)
            return try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
                lastStartError = ""
                true
            } catch (t: Throwable) {
                // ForegroundServiceStartNotAllowedException（API 31+）在旧 SDK 上
                // 不存在，所以按 Throwable 兜；只记类名与消息，便于 Dart/日志定位。
                val reason = "${t.javaClass.simpleName}: ${t.message}"
                lastStartError = reason
                Log.w(TAG, "常驻前台服务启动被系统拒绝：$reason", t)
                false
            }
        }

        fun stop(context: Context) {
            try {
                context.stopService(Intent(context, ChatForegroundService::class.java))
            } catch (t: Throwable) {
                Log.w(TAG, "停止常驻前台服务失败", t)
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "Synology Chat"
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: AppLang.s(this, R.string.chat_connecting_foreground)
        try {
            ChatNotifications.ensureChannels(this)
            startForeground(
                NOTIFICATION_ID,
                ChatNotifications.buildServiceNotification(this, title, text),
            )
            running = true
            lastStartError = ""
        } catch (t: Throwable) {
            // Android 12+ 也可能在这里抛（后台启动限制在"真的进前台"这一刻才判）。
            val reason = "${t.javaClass.simpleName}: ${t.message}"
            lastStartError = reason
            running = false
            Log.w(TAG, "进入前台失败，常驻服务退出：$reason", t)
            stopSelf()
        }
        // 被系统杀掉后重建时也继续跑（START_STICKY），配合 Dart 侧重连
        return START_STICKY
    }

    /**
     * Android 15（API 35）引入：带超时的前台服务类型（`dataSync` /
     * `mediaProcessing`）用尽配额时系统会调这里，**必须几秒内 `stopSelf()`**，
     * 否则系统抛 `RemoteServiceException` 直接杀掉进程（logcat 里是
     * "did not stop within its timeout"）。
     *
     * 我们把类型换成了 `specialUse`（无超时），所以正常路径下**不会**被调到；
     * 但这条实现是**零成本的正确性兜底**：真被调到就如实退出前台，
     * 让 Dart 侧下一次进前台时重连重排。
     */
    override fun onTimeout(startId: Int) {
        Log.w(TAG, "前台服务超时（startId=$startId），按系统要求退出前台")
        running = false
        lastStartError = "onTimeout"
        stopSelf(startId)
    }

    /**
     * API 35 的三参重载（带 `foregroundServiceType`）。
     *
     * ⚠️ **不加** `@RequiresApi`：这是"覆写"而不是"调用" —— 旧设备上系统永远
     * 不会调到它，而加了注解会让 lint 认为类/方法只在 35+ 可用。
     */
    override fun onTimeout(startId: Int, fgsType: Int) {
        Log.w(TAG, "前台服务超时（startId=$startId, fgsType=$fgsType），退出前台")
        running = false
        lastStartError = "onTimeout(type=$fgsType)"
        stopSelf(startId)
    }

    override fun onDestroy() {
        running = false
        try {
            NotificationManagerCompat.from(this).cancel(NOTIFICATION_ID)
        } catch (t: Throwable) {
            Log.w(TAG, "撤前台通知失败", t)
        }
        super.onDestroy()
    }
}
