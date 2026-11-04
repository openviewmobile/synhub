// 笔记后台同步的**前台登记通道**（第 114 轮 M3）。
//
// Dart 启动时把 `noteBackgroundSyncMain` 的 callback handle 登记给原生，
// 并按用户的开关排/停周期任务。只做三件事：
//   register(handle) → 记住 entrypoint
//   enable()/disable() → 排/停 WorkManager 周期任务
//   syncNow() → 立刻补跑一次（前台"立即同步"/开机补跑）
package com.openviewai.synhub

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

object NoteSyncPlugin {
    const val CHANNEL = "synhub/note_sync"
    const val BG_CHANNEL = "synhub/note_sync_bg"

    fun attach(context: Context, engine: FlutterEngine) {
        val appContext = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "registerCallback" -> {
                        val handle = (call.argument<Number>("handle"))?.toLong() ?: 0L
                        if (handle == 0L) {
                            result.error("bad_args", "handle 不能为 0", null)
                        } else {
                            NoteSyncScheduler.registerCallback(appContext, handle)
                            result.success(true)
                        }
                    }
                    "enable" -> {
                        NoteSyncScheduler.enable(appContext)
                        result.success(true)
                    }
                    "disable" -> {
                        NoteSyncScheduler.disable(appContext)
                        result.success(true)
                    }
                    "isEnabled" -> result.success(NoteSyncScheduler.isEnabled(appContext))
                    "syncNow" -> {
                        NoteSyncScheduler.syncNow(
                            appContext,
                            call.argument<String>("reason") ?: "manual",
                        )
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
