// 设备型号 + **端侧算力画像**桥。
//
// ① 型号（原有）：官方 DSnote 在 `commit_msg.device` 里报 `Build.MODEL`
//    （`SyncPushCallable` / `LoginTask` / `SyncCallable` 三处 smali 取证，
//    第 112 轮），Note Station 把它当版本历史的"来源设备"标签显示。
//
// ② 算力画像（第 253 轮新增，用户要求）：端侧大模型**必须按机器给**——
//    "不同的手机看到的是不同的模型，不能所有手机统一下载使用同一套模型；
//    硬件太差的设备要把端侧大模型模块隐藏"。
//    这里只负责**如实采集**事实，**原生侧不做任何推荐决策**
//    （推荐/隐藏规则放 Dart 侧，便于单测与审计）：
//      * SoC：`Build.SOC_MODEL`/`SOC_MANUFACTURER`（API 31+），回落 `Build.HARDWARE`
//      * CPU：核数、`/proc/cpuinfo` Features、cpu0 最大频率（读不到就 0）
//      * 内存：`ActivityManager.MemoryInfo`（totalMem/availMem/lowMemory/isLowRamDevice）
//      * 存储：应用数据目录所在分区的 `StatFs` 剩余/总字节
//      * GPU：自建 EGL/GLES2 上下文读 `GL_RENDERER/GL_VENDOR/GL_VERSION`
//      * GPU 后端（LiteRT-LM 的 GPU 委托走 OpenCL）：只查 `libOpenCL.so` 在不在
//      * NPU：`hasSystemFeature("android.hardware.neuralnetworks")`
//        —— 这只是 **NNAPI 能力存在性**，不代表某 SoC 的 NPU 能被 LiteRT 用上；
//        真正的 NPU 判定在 Dart 侧 SoC 表里（如 MT6993 的 a16w8 变体）
//
// 三条纪律（与 `device_model.dart` 一致）：
//   ① **只读**：不申请权限、不写文件、不改设置；
//   ② 逐项 try/catch：拿不到就回 0/false/""，**不把异常抛给 Dart**；
//   ③ 原生侧不缓存（Dart 侧有 provider 缓存），每次都是当下事实。
package com.openviewai.synhub

import android.app.ActivityManager
import android.content.Context
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.GLES20
import android.os.Build
import android.os.PowerManager
import android.os.StatFs
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

object DeviceModelBridge {
    const val CHANNEL = "synhub/device"

    fun attach(context: Context, engine: FlutterEngine) {
        val app = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // 官方口径是**原样** `Build.MODEL`（**不做**文件名净化 ——
                    // 净化是照片备份那条路的需求，两者不要混）
                    "model" -> result.success(Build.MODEL ?: "")
                    // 顺带给一个品牌+型号，便于"来源设备"更可读
                    "brandModel" -> {
                        val brand = Build.BRAND ?: ""
                        val model = Build.MODEL ?: ""
                        result.success(
                            if (brand.isEmpty()) model else "$brand $model"
                        )
                    }
                    "capability" -> result.success(capability(app))
                    else -> result.notImplemented()
                }
            }
    }

    private fun capability(context: Context): Map<String, Any> {
        val out = HashMap<String, Any>()
        // --- 设备身份 ---
        out["manufacturer"] = Build.MANUFACTURER ?: ""
        out["brand"] = Build.BRAND ?: ""
        out["model"] = Build.MODEL ?: ""
        out["device"] = Build.DEVICE ?: ""
        out["board"] = Build.BOARD ?: ""
        out["hardware"] = Build.HARDWARE ?: ""
        out["socModel"] = if (Build.VERSION.SDK_INT >= 31) {
            Build.SOC_MODEL ?: ""
        } else {
            ""
        }
        out["socManufacturer"] = if (Build.VERSION.SDK_INT >= 31) {
            Build.SOC_MANUFACTURER ?: ""
        } else {
            ""
        }
        out["sdkInt"] = Build.VERSION.SDK_INT
        out["release"] = Build.VERSION.RELEASE ?: ""
        out["abis"] = Build.SUPPORTED_ABIS?.toList() ?: emptyList<String>()

        // --- CPU ---
        out["cpuCores"] = try {
            Runtime.getRuntime().availableProcessors()
        } catch (t: Throwable) {
            0
        }
        out["cpuFeatures"] = try {
            File("/proc/cpuinfo").readLines()
                .firstOrNull { it.startsWith("Features") || it.startsWith("flags") }
                ?.substringAfter(':')
                ?.trim()
                ?: ""
        } catch (t: Throwable) {
            ""
        }
        out["cpuMaxFreqKhz"] = try {
            File("/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq")
                .readText().trim().toLong()
        } catch (t: Throwable) {
            0L
        }

        // --- 内存 ---
        try {
            val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val mi = ActivityManager.MemoryInfo()
            am.getMemoryInfo(mi)
            out["totalRamBytes"] = mi.totalMem
            out["availRamBytes"] = mi.availMem
            out["lowMemory"] = mi.lowMemory
            out["lowRamDevice"] = am.isLowRamDevice
        } catch (t: Throwable) {
            out["totalRamBytes"] = 0L
            out["availRamBytes"] = 0L
            out["lowMemory"] = false
            out["lowRamDevice"] = false
        }

        // --- 存储（应用数据目录所在分区） ---
        try {
            val stat = StatFs(context.filesDir.absolutePath)
            out["freeStorageBytes"] = stat.availableBytes
            out["totalStorageBytes"] = stat.totalBytes
        } catch (t: Throwable) {
            out["freeStorageBytes"] = 0L
            out["totalStorageBytes"] = 0L
        }

        // --- GPU（EGL/GLES2 一趟） ---
        val gl = glInfo()
        out["glRenderer"] = gl[0]
        out["glVendor"] = gl[1]
        out["glVersion"] = gl[2]

        // --- GPU 计算后端（LiteRT-LM 的 GPU 委托走 OpenCL） ---
        out["openclLibrary"] = try {
            listOf(
                "/vendor/lib64/libOpenCL.so",
                "/system/lib64/libOpenCL.so",
                "/vendor/lib/libOpenCL.so",
                "/system/lib/libOpenCL.so",
            ).any { File(it).exists() }
        } catch (t: Throwable) {
            false
        }

        // --- NPU（只报"NNAPI 能力存在性"） ---
        out["nnapiFeature"] = try {
            context.packageManager.hasSystemFeature(
                "android.hardware.neuralnetworks"
            )
        } catch (t: Throwable) {
            false
        }

        // --- 热状态（当下快照，不是能力；仅用于报告） ---
        out["thermalStatus"] = try {
            if (Build.VERSION.SDK_INT >= 29) {
                val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
                pm.currentThermalStatus
            } else {
                -1
            }
        } catch (t: Throwable) {
            -1
        }
        return out
    }

    /** 返回 `[renderer, vendor, version]`；任一步失败就是空串，不抛。 */
    private fun glInfo(): Array<String> {
        val none = arrayOf("", "", "")
        var display = EGL14.EGL_NO_DISPLAY
        var context = EGL14.EGL_NO_CONTEXT
        var surface = EGL14.EGL_NO_SURFACE
        return try {
            display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
            if (display == EGL14.EGL_NO_DISPLAY) return none
            val version = IntArray(2)
            if (!EGL14.eglInitialize(display, version, 0, version, 1)) return none
            val attribs = intArrayOf(
                EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
                EGL14.EGL_NONE,
            )
            val configs = arrayOfNulls<EGLConfig>(1)
            val numConfig = IntArray(1)
            if (!EGL14.eglChooseConfig(display, attribs, 0, configs, 0, 1, numConfig, 0)) {
                return none
            }
            val cfg = configs[0] ?: return none
            context = EGL14.eglCreateContext(
                display, cfg, EGL14.EGL_NO_CONTEXT,
                intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0,
            )
            if (context == EGL14.EGL_NO_CONTEXT) return none
            surface = EGL14.eglCreatePbufferSurface(
                display, cfg,
                intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE), 0,
            )
            if (surface == EGL14.EGL_NO_SURFACE) return none
            if (!EGL14.eglMakeCurrent(display, surface, surface, context)) return none
            arrayOf(
                GLES20.glGetString(GLES20.GL_RENDERER) ?: "",
                GLES20.glGetString(GLES20.GL_VENDOR) ?: "",
                GLES20.glGetString(GLES20.GL_VERSION) ?: "",
            )
        } catch (t: Throwable) {
            none
        } finally {
            try {
                EGL14.eglMakeCurrent(
                    display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE,
                    EGL14.EGL_NO_CONTEXT,
                )
                if (surface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(display, surface)
                if (context != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(display, context)
                if (display != EGL14.EGL_NO_DISPLAY) EGL14.eglTerminate(display)
            } catch (t: Throwable) {
                // 释放失败不影响返回值
            }
        }
    }
}
