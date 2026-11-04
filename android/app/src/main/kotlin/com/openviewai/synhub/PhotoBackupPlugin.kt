// 相册「手机自动备份」的 **Android 平台层**（WorkManager + 后台 FlutterEngine）。
//
// 与 Dart 的接口（MethodChannel `synhub/photo_backup`）：
//   Dart→原生：registerCallback / status / setSchedule / runNow / cancel /
//              reportForeground / requestIgnoreBatteryOptimization
//   原生→Dart（**后台引擎**，MethodChannel `synhub/photo_backup_bg`）：
//              由 `PhotoBackupWorker` 在 WorkManager 线程里拉起一个 headless
//              FlutterEngine，调 `runBackup` —— 真正跑 Dart 备份逻辑，
//              本文件/Worker **不重写**备份算法。
//
// 为什么是 WorkManager 而不是 AlarmManager（对照 NoteReminderPlugin）：
//   * 相册备份是"可延迟的批量同步"，不是"准点响铃"：官方 Synology Photos
//     的 `BackupWork` 就是 `PeriodicWorkRequest`（1 小时周期）+ 充电/网络约束；
//   * 约束（充电 / Wi-Fi / 息屏）交给系统判定，比自研轮询省电且 Doze 友好；
//   * 官方通知渠道 `str_noti_channel_photo_backup = "Backup process"`
//     （见 res 的 `photo_backup_channel_name`），前台服务类型 dataSync
//     （Android 14+ 必须声明 `FOREGROUND_SERVICE_DATA_SYNC`）。
//
// 前台/后台互斥：Dart 前台队列在跑时调 `reportForeground(true)`，Worker 见到
// `foregroundRunning` 就直接成功返回，**不重复传同一批照片**。
package com.openviewai.synhub

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

object PhotoBackupPlugin {
    /** Dart↔原生 的**前台**通道（设置页/状态查询/排程）。 */
    const val CHANNEL = "synhub/photo_backup"

    /** 原生↔Dart 的**后台**通道（headless 引擎里跑 `runBackup`）。 */
    const val BG_CHANNEL = "synhub/photo_backup_bg"

    /** WorkManager 的 unique work 名（周期任务；一次性任务加 `-now` 后缀）。 */
    const val WORK_NAME = "photo_backup_work"

    /** 官方通知渠道 id（Synology Photos `str_noti_channel_photo_backup`）。 */
    const val CHANNEL_ID = "photo_backup"

    /** 息屏触发备份的 action（`PhotoBackupScreenOffReceiver` 用系统 SCREEN_OFF）。 */
    const val ACTION_SCREEN_OFF_BACKUP = "com.openviewai.synhub.PHOTO_BACKUP_SCREEN_OFF"

    internal const val TAG = "SynologyChatPhoto"

    // SharedPreferences：Dart 的 callback handle + 用户设置 + 上次结果
    internal const val PREFS = "synhub_photo_backup"
    internal const val KEY_CALLBACK_HANDLE = "callback_handle"
    internal const val KEY_ENABLED = "enabled"
    internal const val KEY_CHARGE_ONLY = "charge_only"
    internal const val KEY_SCREEN_OFF_ONLY = "screen_off_only"
    internal const val KEY_WIFI_ONLY = "wifi_only"
    internal const val KEY_DESTINATION = "destination"
    internal const val KEY_LAST_RESULT = "last_result"

    internal const val DEST_DRIVE = "drive"
    internal const val DEST_SYNOLOGY_PHOTOS = "synology_photos"

    /**
     * 前台队列是否正在备份（Dart 通过 `reportForeground` 上报）。
     * 与 WorkManager 后台任务**互斥**：前台在跑，后台不重复跑。
     */
    @Volatile
    var foregroundRunning: Boolean = false

    private var channelRef: MethodChannel? = null

    // ------------------------------------------------------------------ 生命周期

    fun attach(context: Context, engine: FlutterEngine) {
        ensureChannel(context)
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        channelRef = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "registerCallback" -> {
                    val handle = ((call.arguments as? Map<*, *>)?.get("handle") as? Number)?.toLong()
                    if (handle == null || handle <= 0L) {
                        Log.w(TAG, "registerCallback：handle 非法（$handle）")
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    prefs(context).edit().putLong(KEY_CALLBACK_HANDLE, handle).apply()
                    Log.i(TAG, "已注册后台回调 handle=$handle")
                    result.success(true)
                }

                "status" -> result.success(statusMap(context))

                "setSchedule" -> {
                    val ok = try {
                        applySchedule(context, call.arguments as? Map<*, *>)
                    } catch (e: Exception) {
                        // 不许静默失败：异常也如实返回 false，Dart 会回落前台队列
                        Log.w(TAG, "setSchedule 失败", e)
                        false
                    }
                    result.success(ok)
                }

                "runNow" -> result.success(PhotoBackupWorker.enqueueNow(context))

                "cancel" -> {
                    PhotoBackupWorker.cancel(context)
                    result.success(true)
                }

                "reportForeground" -> {
                    val running =
                        (call.arguments as? Map<*, *>)?.get("running") as? Boolean ?: false
                    foregroundRunning = running
                    Log.i(TAG, "前台备份状态上报：running=$running")
                    result.success(true)
                }

                "requestIgnoreBatteryOptimization" ->
                    result.success(requestIgnoreBatteryOptimization(context))

                else -> result.notImplemented()
            }
        }
    }

    // ------------------------------------------------------------------ 排程持久化

    /**
     * 官方语义：`enabled` 关闭 → 撤销全部后台任务；开启 → 用新约束重排周期任务 +
     * 立刻排一次一次性任务（"改设置马上生效"）。
     *
     * @return false = WorkManager 侧出事（见日志），Dart 侧应据此提示。
     */
    internal fun applySchedule(context: Context, args: Map<*, *>?): Boolean {
        val enabled = args?.get("enabled") as? Boolean ?: false
        val chargeOnly = args?.get("chargeOnly") as? Boolean ?: false
        val screenOffOnly = args?.get("screenOffOnly") as? Boolean ?: false
        val wifiOnly = args?.get("wifiOnly") as? Boolean ?: false
        val destination = (args?.get("destination") as? String)
            ?.takeIf { it == DEST_DRIVE || it == DEST_SYNOLOGY_PHOTOS }
            ?: DEST_SYNOLOGY_PHOTOS

        // 先落盘（Worker 的约束/目标都从 prefs 读，顺序不能反）
        prefs(context).edit()
            .putBoolean(KEY_ENABLED, enabled)
            .putBoolean(KEY_CHARGE_ONLY, chargeOnly)
            .putBoolean(KEY_SCREEN_OFF_ONLY, screenOffOnly)
            .putBoolean(KEY_WIFI_ONLY, wifiOnly)
            .putString(KEY_DESTINATION, destination)
            .apply()

        return try {
            if (enabled) {
                PhotoBackupWorker.schedule(context, chargeOnly, screenOffOnly, wifiOnly)
                Log.i(
                    TAG,
                    "相册备份已排程：chargeOnly=$chargeOnly screenOffOnly=$screenOffOnly " +
                        "wifiOnly=$wifiOnly destination=$destination",
                )
            } else {
                PhotoBackupWorker.cancel(context)
                Log.i(TAG, "相册备份已关闭，后台任务已撤销")
            }
            true
        } catch (e: Exception) {
            Log.w(TAG, "排程/撤销 WorkManager 失败", e)
            false
        }
    }

    // ------------------------------------------------------------------ 能力/状态

    /** 状态页要的**全部事实**（键名与 Dart 侧一一对应，不要随意增删）。 */
    internal fun statusMap(context: Context): Map<String, Any> {
        val notificationsGranted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.POST_NOTIFICATIONS,
            ) == PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
        val pm = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
        return mapOf(
            "supported" to true,
            "scheduled" to PhotoBackupWorker.isScheduled(context),
            "charging" to isCharging(context),
            "screenInteractive" to (pm?.isInteractive ?: true),
            "notificationsGranted" to notificationsGranted,
            "batteryOptimizationIgnored" to isIgnoringBatteryOptimizations(context),
            "deviceName" to deviceName(),
            "lastResult" to prefs(context).getString(KEY_LAST_RESULT, "").orEmpty(),
            "destination" to getDestination(context),
            "enabled" to isEnabled(context),
            "chargeOnly" to isChargeOnly(context),
            "screenOffOnly" to isScreenOffOnly(context),
            "wifiOnly" to isWifiOnly(context),
        )
    }

    /** API 21+：`BATTERY_PROPERTY_STATUS` 是否在充电/已满。 */
    internal fun isCharging(context: Context): Boolean {
        val bm = context.getSystemService(Context.BATTERY_SERVICE) as? BatteryManager
        if (bm == null) {
            Log.w(TAG, "没有 BatteryManager，充电状态按未充电处理")
            return false
        }
        return when (bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_STATUS)) {
            BatteryManager.BATTERY_STATUS_CHARGING,
            BatteryManager.BATTERY_STATUS_FULL,
            -> true
            else -> false
        }
    }

    /** 白名单豁免（API<23 视作已豁免）。 */
    internal fun isIgnoringBatteryOptimizations(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val pm = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
        if (pm == null) {
            Log.w(TAG, "没有 PowerManager，电池优化豁免按未豁免处理")
            return false
        }
        return pm.isIgnoringBatteryOptimizations(context.packageName)
    }

    /**
     * 拉起系统的"电池优化白名单"页（官方 Photos 也引导用户加白，否则 OEM
     * 省电策略会在后台掐掉 Worker）。
     *
     * @return 当前是否已豁免（拉起页面本身不改状态，用户回来后再 `status()` 刷新）。
     */
    private fun requestIgnoreBatteryOptimization(context: Context): Boolean {
        val ignored = isIgnoringBatteryOptimizations(context)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !ignored) {
            try {
                context.startActivity(
                    Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
            } catch (e: Exception) {
                Log.w(TAG, "无法打开电池优化白名单页", e)
            }
        }
        return ignored
    }

    /**
     * 设备型号 → 每台设备一个子目录的**安全目录名**（官方 Drive/Photos 备份都用
     * 设备型号做层级，如 `/mydrive/PhotoBackup/<device>/`）。
     *
     * 规则：只保留 `[A-Za-z0-9._-]`，其余（含空格）一律换成 `_`；连续 `_` 折叠成
     * 一个；首尾 `_` 去掉；空结果回落 `"Android"`。
     */
    internal fun deviceName(): String {
        val raw = Build.MODEL ?: ""
        val sb = StringBuilder()
        var lastUnderscore = false
        for (c in raw) {
            if (isAllowedNameChar(c)) {
                sb.append(c)
                lastUnderscore = false
            } else if (!lastUnderscore) {
                sb.append('_')
                lastUnderscore = true
            }
        }
        val sanitized = sb.toString().trim('_')
        return if (sanitized.isEmpty()) "Android" else sanitized
    }

    private fun isAllowedNameChar(c: Char): Boolean =
        (c in 'A'..'Z') || (c in 'a'..'z') || (c in '0'..'9') || c == '.' || c == '_' || c == '-'

    // ------------------------------------------------------------------ prefs 读取

    internal fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** 后台入口 Dart 的 callback handle（未注册 = -1）。 */
    internal fun getCallbackHandle(context: Context): Long =
        prefs(context).getLong(KEY_CALLBACK_HANDLE, -1L)

    internal fun isEnabled(context: Context): Boolean =
        prefs(context).getBoolean(KEY_ENABLED, false)

    internal fun isChargeOnly(context: Context): Boolean =
        prefs(context).getBoolean(KEY_CHARGE_ONLY, false)

    internal fun isScreenOffOnly(context: Context): Boolean =
        prefs(context).getBoolean(KEY_SCREEN_OFF_ONLY, false)

    internal fun isWifiOnly(context: Context): Boolean =
        prefs(context).getBoolean(KEY_WIFI_ONLY, true)

    internal fun getDestination(context: Context): String =
        prefs(context).getString(KEY_DESTINATION, DEST_SYNOLOGY_PHOTOS)
            ?.takeIf { it == DEST_DRIVE || it == DEST_SYNOLOGY_PHOTOS }
            ?: DEST_SYNOLOGY_PHOTOS

    /** Worker 跑完写回一句人话摘要（状态页展示）。 */
    internal fun saveLastResult(context: Context, value: String) {
        prefs(context).edit().putString(KEY_LAST_RESULT, value).apply()
    }

    // ------------------------------------------------------------------ 通知

    internal fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = context.getSystemService(NotificationManager::class.java) ?: return
        // ★ r341 D42：原来是 `context.getString`（跟随**系统**语言）⇒ 真机上中文 App
        //   的系统通知渠道名是英文 `Backup process`。改成 `AppLang.s` 且每次重写。
        val name = AppLang.s(context, R.string.photo_backup_channel_name)
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, name, NotificationManager.IMPORTANCE_LOW)
                .apply { description = name },
        )
    }
}

/**
 * 开机 / 应用更新后把备份任务重新入队（"开机恢复"）。
 *
 * 进程外也能跑：只读本机 prefs，不需要 Flutter 引擎、不需要联网。未启用就跳过。
 */
class PhotoBackupBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != Intent.ACTION_MY_PACKAGE_REPLACED
        ) {
            return
        }
        if (!PhotoBackupPlugin.isEnabled(context)) {
            Log.i(PhotoBackupPlugin.TAG, "开机恢复跳过：相册备份未启用")
            return
        }
        PhotoBackupWorker.enqueueNow(context)
        Log.i(PhotoBackupPlugin.TAG, "开机/更新后重新入队相册备份")
    }
}

/**
 * 息屏触发：只在"仅息屏备份"模式下生效（官方 Photos 的息屏备份开关）。
 *
 * `ACTION_SCREEN_OFF` 是少数仍允许**静态注册**的隐式广播之一，见 manifest。
 */
class PhotoBackupScreenOffReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_SCREEN_OFF) return
        if (!PhotoBackupPlugin.isEnabled(context)) return
        if (!PhotoBackupPlugin.isScreenOffOnly(context)) return
        PhotoBackupWorker.enqueueNow(context)
        Log.i(PhotoBackupPlugin.TAG, "息屏触发：重新入队相册备份")
    }
}
