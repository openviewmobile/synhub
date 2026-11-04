// 当前网络类型（判断"收到通知时要不要预加载消息"，默认仅 Wi-Fi）。
//
// 原版 `ConnectionStateManager.getCurrentNetworkType()` 走
// `ConnectivityManager.getActiveNetworkInfo().getType()`，Wi-Fi = 1。
// 这里只回一个字符串给 Dart（`lib/src/core/net/network_type.dart`）。
package com.openviewai.synhub

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.telephony.TelephonyManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

object NetworkBridge {
    const val CHANNEL = "synhub/network"

    fun attach(context: Context, engine: FlutterEngine) {
        val appContext = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "current" -> result.success(currentType(appContext))
                    "networkCountryIso" -> result.success(networkCountryIso(appContext))
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * 网络**注册地**国家码（`TelephonyManager.getNetworkCountryIso()`，形如 `cn`）。
     *
     * 用途：官方 QuickConnect `QuickConnectUtil.isDeviceInChina(Context)` 的
     * **第一顺位**输入（MCC 非空即判、为空才回落 locale）。
     *
     * 用 `networkCountryIso`（**网络**注册地），**不是** `simCountryIso`（SIM 归属）——
     * 官方 smali 调的正是 `getNetworkCountryIso()`。
     *
     * ★ **拿不到一律回 `null`，绝不回 `false`**：没有电话服务、Wi-Fi-only 设备、
     * 平台异常 —— 全回 `null`，由 Dart 侧按官方同款顺序**回落 locale**。
     * 回 `false` 会把"不知道"伪造成"不在中国"。
     */
    private fun networkCountryIso(context: Context): String? {
        val tm = context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
            ?: return null
        val iso = try {
            tm.networkCountryIso
        } catch (_: SecurityException) {
            null
        } catch (_: Exception) {
            null
        }
        val trimmed = iso?.trim().orEmpty()
        return trimmed.ifEmpty { null }
    }

    private fun currentType(context: Context): String {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE)
            as? ConnectivityManager ?: return "unknown"
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val caps = cm.activeNetwork?.let { cm.getNetworkCapabilities(it) }
                ?: return "none"
            when {
                caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "mobile"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "other"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> "other"
                else -> "unknown"
            }
        } else {
            @Suppress("DEPRECATION")
            when (cm.activeNetworkInfo?.type) {
                ConnectivityManager.TYPE_WIFI -> "wifi"
                ConnectivityManager.TYPE_MOBILE -> "mobile"
                ConnectivityManager.TYPE_ETHERNET -> "other"
                null -> "none"
                else -> "unknown"
            }
        }
    }
}
