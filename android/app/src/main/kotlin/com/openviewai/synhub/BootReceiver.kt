// Phase 8：开机自启。
//
// 限制说清楚：Android 上开机后没有 Flutter 引擎，Dart 侧的 socket 起不来。
// 所以这里做的是**把常驻服务拉起来**（恢复前台通知 + START_STICKY），
// 用户打开 App 时 Dart 侧会立刻重连并刷新服务通知内容。
//
// ★ 第 278 轮修正了两处（都对 Android 15 / API 35 有实际影响）：
//
//   ① **不再假设"开机拉前台服务一定成功"**。Android 12（API 31）起
//      "以 Android 12 或更高版本为目标平台的应用无法在后台运行时启动前台服务，
//      少数特殊情况除外。如果应用尝试在后台运行时启动前台服务，则会引发异常"
//      （官方 behavior-changes-12 逐字）；Android 15 起**开机广播**还单独禁掉了
//      一批类型。BOOT_COMPLETED 属于"临时豁免"，但**不是无条件**成功，
//      所以这里按"可能失败"处理：`ChatForegroundService.start` 返回 false 就
//      只记日志（它内部已经捕获 `ForegroundServiceStartNotAllowedException`），
//      **绝不**让开机广播抛异常（那会变成开机时的 `RemoteServiceException`/ANR）。
//   ② **修正一条错误的注释**：旧注释写"BOOT_COMPLETED 属于允许后台启动 Activity
//      的例外"——**这是错的**。官方《限制从后台启动 activity》列出的例外是
//      「有可见窗口 / 是当前输入法 / 从系统 PendingIntent 启动 /
//      有 SYSTEM_ALERT_WINDOW / 有 START_ACTIVITIES_FROM_BACKGROUND /
//      绑定到已获准的服务 / 启动器发起 / 系统核心组件」，**没有 BOOT_COMPLETED**。
//      也就是说 API 29+ 上这段 `startActivity` 一直是**静默无效**的。
//      现在包了 try/catch 并且注释如实说明（真正的保活手段是**前台服务通知**，
//      不是把界面硬拉到前台 —— 后者对用户也是打扰）。
package com.openviewai.synhub

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

class BootReceiver : BroadcastReceiver() {
    private companion object {
        const val TAG = "SynologyChatBoot"
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED &&
            intent.action != Intent.ACTION_MY_PACKAGE_REPLACED
        ) {
            return
        }
        // ★ 第 114 轮（M3）：开机/升级后**补排笔记后台同步**
        //   （官方是 `Utils.resumeSyncService`；用户的开关优先，关过就不排）。
        //   放在 autostart 判定**之前** —— 笔记同步与"聊天自启"是两件事。
        NoteSyncScheduler.rescheduleIfEnabled(context)

        val prefs = context.getSharedPreferences("synhub", Context.MODE_PRIVATE)
        if (!prefs.getBoolean("autostart", false)) return

        // ★ 第 278 轮：可能被系统拒绝（API 31+ 后台启动限制 / API 35 开机类型限制）
        // ⇒ start() 返回 false，只记日志。开机广播里抛异常会让整条链路"炸在开机"。
        val started = ChatForegroundService.start(context, "Synology Chat", AppLang.s(context, R.string.chat_reconnecting_foreground))
        if (!started) {
            Log.w(
                TAG,
                "开机拉起常驻前台服务被系统拒绝：${ChatForegroundService.lastStartError}；" +
                    "保活改由用户打开 App 时建立（设置里的「后台保活」页有厂商放行指引）",
            )
        }

        if (prefs.getBoolean("autostartForeground", false)) {
            // ⚠️ API 29+ 上这**不是**豁免动作，系统会静默丢弃（见文件头 ②）。
            // 保留是为了旧版本（minSdk 24）与用户显式开启的语义；包 try/catch
            // 以免个别 ROM 抛 SecurityException 把开机广播打崩。
            try {
                context.startActivity(
                    Intent(context, MainActivity::class.java)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
            } catch (t: Throwable) {
                Log.w(TAG, "开机拉起主界面失败（API 29+ 属预期：非后台启动 activity 的豁免）", t)
            }
        }
    }
}
