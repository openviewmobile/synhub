// **只读**的按 UID 流量计数桥（第 276 轮）。
//
// 目的：Dart HTTP 客户端（Dio）量得到"精确档"流量，但 ExoPlayer（video_player
// / just_audio）、原生抽帧桥、原生 Audio Station 流这些**绕过 Dart** 的流量
// 量不到。Android 只提供**按 UID** 的累计计数
// （`android.net.TrafficStats.getUidRxBytes/getUidTxBytes`，另有**整机**的
// `getTotal*`），无法拆到模块 —— 所以 Dart 侧只在**已知活动会话**前后各采
// 一次快照做差分，并如实记成 `estimated`（见 `core/net/device_traffic.dart`）。
//
// ★ 实测结论（`javap android.net.TrafficStats`，android-36）：
//   公开 API 里**没有按 UID 的移动数据计数**（只有整机的
//   `getMobileRxBytes/getMobileTxBytes`）⇒ 移动数据这两项一律回 `-1`
//   （"读不到" ≠ "没流量"），不用整机数字冒充本 App 的。
//
// 本文件的三条纪律：
//   1. **只读**：只调用 `TrafficStats.get*`，不申请任何权限、不写任何东西；
//   2. **不轮询**：谁调用 `uidSnapshot` 谁负责节流（Dart 侧只在会话边界调）；
//   3. **不可读就如实回 -1**：`TrafficStats` 在部分设备/版本返回
//      `UNSUPPORTED(-1)`，不要把它当 0（"读不到" ≠ "没流量"）。
package com.openviewai.synhub

import android.net.TrafficStats
import android.os.Process
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

object TrafficStatsBridge {
    const val CHANNEL = "synhub/traffic"

    fun attach(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "uidSnapshot" -> result.success(snapshot())
                    else -> result.notImplemented()
                }
            }
    }

    /// 当前进程 UID 的累计计数（字节）。
    ///
    /// 键名与 Dart `DeviceTrafficSnapshot.fromMap` 严格一致：
    /// `uidRx` / `uidTx` / `mobileRx` / `mobileTx` / `totalRx` / `totalTx`。
    private fun snapshot(): Map<String, Any> {
        val uid = Process.myUid()
        return mapOf(
            "uidRx" to TrafficStats.getUidRxBytes(uid).toLong(),
            "uidTx" to TrafficStats.getUidTxBytes(uid).toLong(),
            // 没有按 UID 的移动数据 API（见文件头实测结论）⇒ 如实回 -1
            "mobileRx" to -1L,
            "mobileTx" to -1L,
            "totalRx" to TrafficStats.getTotalRxBytes().toLong(),
            "totalTx" to TrafficStats.getTotalTxBytes().toLong(),
        )
    }
}
