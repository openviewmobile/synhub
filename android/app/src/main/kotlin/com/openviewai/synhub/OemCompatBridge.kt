// ★ 厂商（OEM）兼容事实桥 —— **只读**采集 + 打开系统设置页（第 278 轮）。
//
// 为什么原生侧要做这件事：本 App **故意不用 FCM**（AGENTS §2 硬约束），于是
// 国内 ROM 的「应用启动管理 / 自启动 / 智能省电 / 深度睡眠」直接决定
// "后台服务活不活、通知到不到"。而**每家 ROM 的设置页组件名都不一样**，
// 且不同 ROM 版本会改名 —— 所以这里不"硬启动"，而是：
//
//   ① 用 `Build.MANUFACTURER` / `Build.BRAND` 判厂商（纯字符串，见 [oemId]）；
//   ② 把该厂商的历史组件名当作**候选**，逐个 `PackageManager.resolveActivity`
//      **验真**，只把"这台机器上真的能打开"的那一个返回给 Dart；
//   ③ 一个都验不到 ⇒ 回空串 ⇒ Dart 侧只显示手动路径
//      （`oemAutostartMissing`），**绝不摆一个点了会报错的按钮**。
//
// 纪律（与 `DeviceModelBridge` 一致）：
//   * **只读**：`status` 不申请权限、不写文件、不改设置、不启动 Activity；
//   * 逐项 try/catch：拿不到就回 ""/false，不把异常抛给 Dart；
//   * `openSettings` 只**打开系统设置页**（`ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS`
//     等），不改本 App 任何状态 —— 不是变更动词（AGENTS §5.1）；
//   * 原样返回 `Build.MANUFACTURER`，**不做**任何指纹伪造/隐藏。
//
// 包可见性（Android 11+ / API 30+）：`resolveActivity` 受 `<queries>` 过滤，
// 所以 `AndroidManifest.xml` 的 `<queries>` 里逐条声明了本文件会探测的
// **厂商系统设置包**（见 manifest 的注释；不声明就会"明明有页面却探不到"，
// 与既有 `MediaOpenBridge` 的 video/mp4 事故同一类）。
//
// 证据档位（完整矩阵见 `docs/android-compat-matrix.md` §2）：
//   * `honor` —— **真机验证**（HONOR LGE-AN10 / Android 12 / MagicUI 6.0.0）：
//     `com.hihonor.systemmanager/.startupmgr.ui.StartupNormalAppListActivity`
//     与 `/power.ui.PowerSettingActivity` 实测可 resolve，
//     且 `android.settings.IGNORE_BATTERY_OPTIMIZATION_SETTINGS` 在这台机器上
//     解析到 `com.android.settings/.Settings$HighPowerApplicationsActivity`；
//   * 其余厂商 —— **仅文档**（组件名来自公开资料/各 ROM 历史版本），本机没有
//     对应设备 ⇒ 一律走"验真后才可用"，不存在就当没有。
package com.openviewai.synhub

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

object OemCompatBridge {
    const val CHANNEL = "synhub/oem"
    private const val TAG = "SynologyChatOem"

    fun attach(context: Context, engine: FlutterEngine) {
        val app = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "status" -> result.success(status(app))
                    "openSettings" -> {
                        val target = call.argument<String>("target") ?: ""
                        result.success(openSettings(app, target))
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // --------------------------------------------------------------- 厂商判定

    /**
     * `MANUFACTURER` + `BRAND` → 稳定的厂商 id（**纯函数**，与 Dart 的
     * `OemVendor.id` 一一对应；改一边必须改两边）。
     *
     * 判定顺序有讲究（每条都有理由）：
     *   * **honor 先于 huawei**：荣耀分家前的机器 `BRAND=HONOR` 而
     *     `MANUFACTURER=HUAWEI`，分家后 `MANUFACTURER=HONOR`；两种都要落到 honor；
     *   * **realme 先于 oppo**：realme 与 OPPO/ColorOS 同源但有自己的包名；
     *   * **oneplus 先于 oppo**：一加自 ColorOS 合并后 BRAND 仍可能带 oppo；
     *   * 全部小写比较，避免 ROM 大小写不一致（`HONOR` / `Honor` / `honor`）。
     */
    internal fun oemId(manufacturer: String, brand: String): String {
        val s = (manufacturer + " " + brand).lowercase(Locale.ROOT)
        return when {
            s.contains("honor") || s.contains("hihonor") -> "honor"
            s.contains("huawei") -> "huawei"
            s.contains("xiaomi") || s.contains("redmi") || s.contains("poco") -> "xiaomi"
            s.contains("realme") -> "realme"
            s.contains("oneplus") -> "oneplus"
            s.contains("oppo") || s.contains("oplus") -> "oppo"
            s.contains("vivo") || s.contains("iqoo") -> "vivo"
            s.contains("samsung") -> "samsung"
            s.contains("meizu") -> "meizu"
            s.contains("tecno") || s.contains("infinix") || s.contains("itel") ||
                s.contains("transsion") -> "transsion"
            s.contains("google") -> "google"
            else -> "other"
        }
    }

    /**
     * 该厂商「自启动 / 应用启动管理」页的**历史组件名候选**（有序，第一个能
     * resolve 的胜出）。
     *
     * 每条都是 `包/类` 的**显式组件** —— 只探测、只启动这一页，不广播、不查询
     * 其它数据。厂商改版会让旧组件消失，所以给多条而不是一条。
     */
    internal fun autostartCandidates(oem: String): List<ComponentName> = when (oem) {
        "xiaomi" -> listOf(
            ComponentName(
                "com.miui.securitycenter",
                "com.miui.permcenter.autostart.AutoStartManagementActivity",
            ),
        )
        "huawei" -> listOf(
            ComponentName(
                "com.huawei.systemmanager",
                "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
            ),
            ComponentName(
                "com.huawei.systemmanager",
                "com.huawei.systemmanager.appcontrol.activity.StartupAppControlActivity",
            ),
            // 更老的 EMUI 把"受保护应用"放在这里
            ComponentName(
                "com.huawei.systemmanager",
                "com.huawei.systemmanager.optimize.process.ProtectActivity",
            ),
        )
        // ★ 真机验证过的就是这两条（HONOR LGE-AN10 / MagicUI 6.0.0）
        "honor" -> listOf(
            ComponentName(
                "com.hihonor.systemmanager",
                "com.hihonor.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
            ),
            ComponentName(
                "com.hihonor.systemmanager",
                "com.hihonor.systemmanager.appcontrol.activity.StartupAppControlActivity",
            ),
        )
        "oppo", "realme" -> listOf(
            ComponentName(
                "com.coloros.safecenter",
                "com.coloros.safecenter.permission.startup.StartupAppListActivity",
            ),
            ComponentName(
                "com.oplus.safecenter",
                "com.oplus.safecenter.permission.startup.StartupAppListActivity",
            ),
            ComponentName(
                "com.oppo.safe",
                "com.oppo.safe.permission.startup.StartupAppListActivity",
            ),
        )
        "oneplus" -> listOf(
            ComponentName(
                "com.oplus.safecenter",
                "com.oplus.safecenter.permission.startup.StartupAppListActivity",
            ),
            ComponentName(
                "com.oneplus.security",
                "com.oneplus.security.chainlaunch.view.ChainLaunchAppListActivity",
            ),
        )
        "vivo" -> listOf(
            ComponentName(
                "com.vivo.permissionmanager",
                "com.vivo.permissionmanager.activity.BgStartUpManagerActivity",
            ),
            ComponentName(
                "com.iqoo.secure",
                "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity",
            ),
        )
        "samsung" -> listOf(
            ComponentName(
                "com.samsung.android.lool",
                "com.samsung.android.sm.ui.battery.BatteryActivity",
            ),
            ComponentName(
                "com.samsung.android.sm_cn",
                "com.samsung.android.sm.ui.battery.BatteryActivity",
            ),
        )
        "meizu" -> listOf(
            ComponentName(
                "com.meizu.safe",
                "com.meizu.safe.permission.SmartBGActivity",
            ),
            ComponentName(
                "com.meizu.safe",
                "com.meizu.safe.security.SHOW_APPSEC",
            ),
        )
        "transsion" -> listOf(
            ComponentName(
                "com.transsion.phonemaster",
                "com.transsion.phonemaster.ui.activity.power.PowerActivity",
            ),
            ComponentName(
                "com.itel.phonemaster",
                "com.itel.phonemaster.ui.activity.power.PowerActivity",
            ),
        )
        // google / other 没有"厂商自启动白名单"这一层
        else -> emptyList()
    }

    /** 该厂商的 ROM 版本串（只用于显示；读不到回 `Build.DISPLAY`）。 */
    internal fun romName(oem: String): String {
        val prop = when (oem) {
            // HyperOS 用 ro.mi.os.version.*，MIUI 用 ro.miui.ui.version.*
            "xiaomi" -> listOf("ro.mi.os.version.name", "ro.miui.ui.version.name")
            "huawei", "honor" -> listOf("ro.build.version.emui")
            else -> emptyList()
        }.firstNotNullOfOrNull { v -> sysProp(v)?.takeIf { it.isNotBlank() } }
        return prop ?: (Build.DISPLAY ?: "")
    }

    /**
     * 读系统属性（`ro.*`）。只用反射调 `android.os.SystemProperties.get`，
     * **只读**、逐项 try/catch —— 读不到就回 null，绝不影响主流程。
     * （平台 API 没有公开的读属性接口；这是业界通行做法。）
     */
    private fun sysProp(key: String): String? = try {
        val c = Class.forName("android.os.SystemProperties")
        val m = c.getMethod("get", String::class.java)
        (m.invoke(null, key) as? String)
    } catch (t: Throwable) {
        null
    }

    // ------------------------------------------------------------- status/open

    private fun isIgnoringBatteryOptimizations(context: Context): Boolean = try {
        val pm = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
        pm?.isIgnoringBatteryOptimizations(context.packageName) ?: false
    } catch (t: Throwable) {
        Log.w(TAG, "读电池优化白名单失败", t)
        false
    }

    /**
     * 第一个能 `resolveActivity` 到的自启动组件；一个都没有 ⇒ ""。
     *
     * ⚠️ 这就是"不猜"的落点：Dart 侧只会为**非空**的返回值摆按钮。
     */
    internal fun resolveAutostart(context: Context, oem: String): String {
        val pm = context.packageManager
        for (c in autostartCandidates(oem)) {
            try {
                val i = Intent().setComponent(c)
                if (pm.resolveActivity(i, 0) != null) {
                    return "${c.packageName}/${c.className}"
                }
            } catch (t: Throwable) {
                Log.w(TAG, "探测组件失败 $c", t)
            }
        }
        return ""
    }

    /** 状态页要的**全部事实**（键名与 Dart `OemCompatStatus` 一一对应）。 */
    internal fun status(context: Context): Map<String, Any> {
        val manufacturer = Build.MANUFACTURER ?: ""
        val brand = Build.BRAND ?: ""
        val oem = oemId(manufacturer, brand)
        return mapOf(
            "supported" to true,
            "oem" to oem,
            "manufacturer" to manufacturer,
            "brand" to brand,
            "model" to (Build.MODEL ?: ""),
            "sdkInt" to Build.VERSION.SDK_INT,
            "rom" to romName(oem),
            "autostartComponent" to resolveAutostart(context, oem),
            "batteryOptimizationIgnored" to isIgnoringBatteryOptimizations(context),
        )
    }

    /**
     * 打开一个系统设置落点。返回 true = 真的发出去了（`startActivity` 没抛）。
     *
     * 落点：
     *   * `autostart`        —— 该厂商**验真过**的自启动页；没验到 ⇒ false
     *     （**不**退化成别处，否则用户点了会到错页面，比失败更糟）；
     *   * `battery_whitelist` —— 系统「电池优化白名单」列表页；
     *     该 action 打不开时退到本 App 应用详情页；
     *   * `app_details`      —— 本 App 的「应用详情」页（万能兜底）。
     */
    internal fun openSettings(context: Context, target: String): Boolean {
        val intent: Intent = when (target) {
            "autostart" -> {
                val oem = oemId(Build.MANUFACTURER ?: "", Build.BRAND ?: "")
                val pm = context.packageManager
                val found = autostartCandidates(oem).firstOrNull { c ->
                    try {
                        pm.resolveActivity(Intent().setComponent(c), 0) != null
                    } catch (t: Throwable) {
                        false
                    }
                } ?: return false
                Intent().setComponent(found)
            }
            "battery_whitelist" -> Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
            "app_details" -> Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.fromParts("package", context.packageName, null),
            )
            else -> return false
        }
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            context.startActivity(intent)
            true
        } catch (t: Throwable) {
            Log.w(TAG, "打开系统设置页失败 target=$target", t)
            // 白名单页在个别 ROM 上会被裁掉 ⇒ 退到应用详情页（那里也有"电池"分页）
            if (target == "battery_whitelist") {
                return try {
                    context.startActivity(
                        Intent(
                            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                            Uri.fromParts("package", context.packageName, null),
                        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    )
                    true
                } catch (t2: Throwable) {
                    Log.w(TAG, "退到应用详情页也失败", t2)
                    false
                }
            }
            false
        }
    }
}
