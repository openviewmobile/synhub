// 系统定位（GPS/网络定位）—— 天气与节假日要"我现在在哪儿"。
//
// 为什么自己开 channel，而不是加 `geolocator`：
//   * 项目里已经有 `KeystoreBridge` / `MediaOpenBridge` / `NetworkBridge` 这套
//     MethodChannel 写法，加一个几十行的桥比引一个带一堆 Android 依赖的插件干净；
//   * 我们只要三件事：**有没有权限**、**要一次当前位置**、**定位开关开没开**。
//     没有持续监听、没有地理围栏、不要 Google Play Services（`LocationManager` 就够）。
//
// 回调路径：MainActivity.onRequestPermissionsResult → [onPermissionResult]。
// `current` 一律在**主线程**回结果，且保证只回一次（超时 / 定位回调竞争时容易回两次，
// 那会让 Dart 侧抛 "Reply already submitted"）。
package com.openviewai.synhub

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

object LocationBridge {
    const val CHANNEL = "synhub/location"
    private const val PERMISSION_REQUEST_CODE = 4311
    private const val FIX_TIMEOUT_MS = 12_000L

    /** 复用最近一次定位最多 10 分钟，避免每次开关卡片都开 GPS */
    private const val REUSE_MS = 10 * 60 * 1000L

    private var pendingResult: MethodChannel.Result? = null
    private var cached: Location? = null

    fun attach(activity: FlutterFragmentActivity, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "status" -> result.success(status(activity))
                    "requestPermission" -> requestPermission(activity, result)
                    "current" -> current(activity, result)
                    "clearCache" -> {
                        cached = null
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /** MainActivity 转发系统权限回调；返回 true 表示这次回调是我们的 */
    fun onPermissionResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != PERMISSION_REQUEST_CODE) return false
        val result = pendingResult ?: return true
        pendingResult = null
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        result.success(granted)
        return true
    }

    private fun granted(context: Context): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    private fun serviceEnabled(context: Context): Boolean {
        val lm = context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
            ?: return false
        return try {
            lm.isProviderEnabled(LocationManager.GPS_PROVIDER) ||
                lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
        } catch (_: Exception) {
            false
        }
    }

    private fun status(context: Context): Map<String, Any?> = mapOf(
        "granted" to granted(context),
        "serviceEnabled" to serviceEnabled(context),
        "hasFix" to (cached != null),
    )

    private fun requestPermission(activity: FlutterFragmentActivity, result: MethodChannel.Result) {
        if (granted(activity)) {
            result.success(true)
            return
        }
        if (pendingResult != null) {
            // 上一次还没回（用户还没点授权弹窗）：直接说"没给"，别排队
            result.success(false)
            return
        }
        pendingResult = result
        Handler(Looper.getMainLooper()).post {
            ActivityCompat.requestPermissions(
                activity,
                arrayOf(
                    Manifest.permission.ACCESS_FINE_LOCATION,
                    Manifest.permission.ACCESS_COARSE_LOCATION,
                ),
                PERMISSION_REQUEST_CODE,
            )
        }
    }

    /** 一次性定位：先看缓存 → 再看 last known → 最后真要一次（带超时） */
    private fun current(activity: FlutterFragmentActivity, result: MethodChannel.Result) {
        val done = AtomicBoolean(false)
        fun reply(map: Map<String, Any?>?) {
            if (done.compareAndSet(false, true)) {
                Handler(Looper.getMainLooper()).post { result.success(map) }
            }
        }

        if (!granted(activity)) {
            reply(null)
            return
        }
        val lm = activity.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
        if (lm == null) {
            reply(null)
            return
        }
        cached?.let {
            if (System.currentTimeMillis() - it.time < REUSE_MS) {
                reply(toMap(it))
                return
            }
        }
        val last = bestLastKnown(lm)
        if (last != null && System.currentTimeMillis() - last.time < REUSE_MS) {
            cached = last
            reply(toMap(last))
            return
        }

        // 超时兜底：真机上室内 GPS 可能要很久，别让 UI 一直转
        Handler(Looper.getMainLooper()).postDelayed({
            // 超时了也别浪费：有 last known（哪怕旧）就先给
            reply(last?.let { toMap(it) })
        }, FIX_TIMEOUT_MS)

        try {
            val provider = when {
                lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER) ->
                    LocationManager.NETWORK_PROVIDER
                lm.isProviderEnabled(LocationManager.GPS_PROVIDER) ->
                    LocationManager.GPS_PROVIDER
                else -> null
            } ?: run {
                reply(last?.let { toMap(it) })
                return
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                lm.getCurrentLocation(
                    provider,
                    CancellationSignal(),
                    activity.mainExecutor,
                ) { loc ->
                    if (loc != null) cached = loc
                    reply(loc?.let { toMap(it) } ?: last?.let { toMap(it) })
                }
            } else {
                @Suppress("DEPRECATION")
                lm.requestSingleUpdate(
                    provider,
                    object : LocationListener {
                        override fun onLocationChanged(location: Location) {
                            cached = location
                            reply(toMap(location))
                        }

                        override fun onProviderEnabled(provider: String) {}
                        override fun onProviderDisabled(provider: String) {}
                        override fun onStatusChanged(p: String?, s: Int, e: Bundle?) {}
                    },
                    Looper.getMainLooper(),
                )
            }
        } catch (e: SecurityException) {
            reply(last?.let { toMap(it) })
        } catch (e: Exception) {
            reply(last?.let { toMap(it) })
        }
    }

    private fun bestLastKnown(lm: LocationManager): Location? {
        val providers = listOf(
            LocationManager.GPS_PROVIDER,
            LocationManager.NETWORK_PROVIDER,
            LocationManager.PASSIVE_PROVIDER,
        )
        var best: Location? = null
        for (p in providers) {
            val loc = try {
                if (!lm.isProviderEnabled(p)) null else lm.getLastKnownLocation(p)
            } catch (_: Exception) {
                null
            } ?: continue
            if (best == null || loc.time > best.time) best = loc
        }
        return best
    }

    private fun toMap(loc: Location): Map<String, Any?> = mapOf(
        "latitude" to loc.latitude,
        "longitude" to loc.longitude,
        "accuracy" to (if (loc.hasAccuracy()) loc.accuracy.toDouble() else null),
        "provider" to loc.provider,
        "time" to loc.time,
    )
}
