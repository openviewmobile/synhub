// ★★ ③Drive 第 246 轮 **D66** 的桥：把 Dart 侧的"启用 SAF 按需下载"落到
// Kotlin 的凭据存储（`DriveSafSession`）。
//
// 通道 `synhub/drive_saf`，方法：
//   * `storeCredentials` `{baseUrl, username, password, otp, deviceId, onDemand}`
//   * `clearCredentials`
//   * `setOnDemand` `{on}`
//   * `status` → `{configured, onDemand, baseUrl, username, hasSid, cachedBytes}`
//   * `clearCache` → 释放的字节数
//   * `prefetch` `{fileId, name}` → 立刻下一份到 provider 缓存（"离线可用"用）
//
// ⚠️ 为什么凭据要**存在 Kotlin 侧**：provider 可能被系统文件选择器在
// Flutter 引擎没起来时拉起（冷启动），那时 Dart 根本不在场；只有
// `SharedPreferences`（+Keystore 加密）两边都能读到。
package com.openviewai.synhub

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

object DriveSafBridge {

    const val CHANNEL = DriveSafSession.CHANNEL

    fun attach(ctx: Context, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "storeCredentials" -> {
                        DriveSafSession.save(
                            ctx,
                            call.argument<String>("baseUrl").orEmpty(),
                            call.argument<String>("username").orEmpty(),
                            call.argument<String>("password").orEmpty(),
                            call.argument<String>("otp").orEmpty(),
                            call.argument<String>("deviceId").orEmpty()
                                .ifEmpty { DriveSafSession.deviceId(ctx) },
                            call.argument<Boolean>("onDemand") ?: true,
                        )
                        result.success(DriveSafSession.status(ctx))
                    }
                    "clearCredentials" -> {
                        DriveSafSession.clear(ctx)
                        result.success(true)
                    }
                    "setOnDemand" -> {
                        DriveSafSession.setOnDemand(ctx, call.argument<Boolean>("on") ?: false)
                        result.success(DriveSafSession.status(ctx))
                    }
                    "status" -> result.success(DriveSafSession.status(ctx))
                    "clearCache" -> result.success(DriveSafSession.clearOnDemandCache(ctx))
                    "prefetch" -> {
                        val fileId = call.argument<String>("fileId").orEmpty()
                        val name = call.argument<String>("name").orEmpty()
                        val f = DriveSafSession.download(ctx, fileId, name)
                        result.success(
                            mapOf(
                                "path" to f.absolutePath,
                                "bytes" to f.length(),
                            )
                        )
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                // 失败要**带原因**（Dart 侧会展示"为什么打不开"）
                result.error("drive_saf_error", e.message ?: e.toString(), null)
            }
        }
    }
}
