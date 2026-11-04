// 文件模块 M68（审计行 220）：把已下载的文件**导出到系统的「下载」目录**。
//
// ## 为什么需要它（用户可见的缺口）
// 我们的下载落盘在 `<应用文档>/downloads` —— 那是**应用私有目录**，
// 用户在系统「文件」App / 电脑上看**根本找不到**，也没法用别的 App 打开或拷走。
// 官方 DS file 的 `DownloadFragment` 是写**公共下载目录**的。
//
// ## 为什么用 MediaStore（而不是直接拼 `/sdcard/Download`）
// Android 10（API 29）起是**分区存储**：直接写公共目录要么被拒，要么在
// Android 11+ 才允许（且需要 `requestLegacyExternalStorage` 之类的例外）。
// `MediaStore.Downloads` 是**官方给的正路**：
//   * **不需要任何运行时权限**（App 往 MediaStore 插入自己的文件是允许的）；
//   * 插入后系统媒体库立刻可见 ⇒ 系统「文件」App 的"下载"分类里能看到；
//   * 用 `IS_PENDING` 保证"写完整才可见"（避免别的 App 读到半个文件）。
//
// API < 29 没有 `MediaStore.Downloads`，退回**直接写公共 Downloads 目录**
// （那条路径需要 `WRITE_EXTERNAL_STORAGE`，由 Dart 侧在调用前自己判断——
//  本项目 minSdk 与实机都是 29+，这条分支是**兜底**，不是主路径）。
//
// ## Dart 侧契约（**由 `lib/src/features/files/media_store_save.dart` 固定**）
//   * 通道 `synhub/mediastore`
//   * 方法 `saveToDownloads`，入参 `{path: String, name: String, mimeType: String}`
//     `path` = **本地已存在的源文件绝对路径**（我们下载下来的那份）
//     返回 **String?** = 写入后的 `content://` URI（成功）；null = 失败
//   * 方法 `isSupported`，返回 **Bool**
//     （API < 29 且没有写权限 ⇒ false，Dart 侧据此把入口置灰并给原因）
//   * 未实现/异常 ⇒ Dart 侧一律降级，**不崩、不报内部话术**。
package com.openviewai.synhub

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

object MediaStoreBridge {
    const val CHANNEL = "synhub/mediastore"

    fun attach(context: Context, engine: FlutterEngine) {
        val app = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isSupported" -> result.success(isSupported(app))
                    "saveToDownloads" -> {
                        val path = call.argument<String>("path")
                        val name = call.argument<String>("name")
                        val mime = call.argument<String>("mimeType")
                            ?: "application/octet-stream"
                        if (path.isNullOrBlank() || name.isNullOrBlank()) {
                            result.error("bad_args", "path/name 不能为空", null)
                            return@setMethodCallHandler
                        }
                        val src = File(path)
                        if (!src.isFile) {
                            result.error("no_source", "源文件不存在", null)
                            return@setMethodCallHandler
                        }
                        try {
                            result.success(saveToDownloads(app, src, name, mime))
                        } catch (e: Exception) {
                            // 交给 Dart 侧降级成一句人话，不把异常原文透给用户。
                            result.error("save_failed", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /** API 29+ 用 MediaStore；更低版本要 `WRITE_EXTERNAL_STORAGE`，没有就不支持。 */
    private fun isSupported(context: Context): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) return true
        return context.checkSelfPermission(
            android.Manifest.permission.WRITE_EXTERNAL_STORAGE,
        ) == android.content.pm.PackageManager.PERMISSION_GRANTED
    }

    /**
     * 返回写入后的 URI 字符串；失败返回 null。
     *
     * MediaStore 对**同名文件会自动改名**（`x (1).txt`），所以不覆盖用户已有文件。
     */
    private fun saveToDownloads(
        context: Context,
        src: File,
        name: String,
        mimeType: String,
    ): String? {
        val resolver = context.contentResolver
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, name)
                put(MediaStore.Downloads.MIME_TYPE, mimeType)
                // 写完之前对别的 App 不可见。
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val uri: Uri = resolver.insert(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                values,
            ) ?: return null
            try {
                resolver.openOutputStream(uri)?.use { out ->
                    src.inputStream().use { input -> input.copyTo(out) }
                } ?: run {
                    resolver.delete(uri, null, null)
                    return null
                }
                val done = ContentValues().apply {
                    put(MediaStore.Downloads.IS_PENDING, 0)
                }
                resolver.update(uri, done, null, null)
                return uri.toString()
            } catch (e: Exception) {
                // 别留半个文件在媒体库里。
                runCatching { resolver.delete(uri, null, null) }
                throw e
            }
        }

        // ---- API < 29 兜底：直接写公共 Downloads 目录 ----
        @Suppress("DEPRECATION")
        val dir = Environment.getExternalStoragePublicDirectory(
            Environment.DIRECTORY_DOWNLOADS,
        )
        if (!dir.exists() && !dir.mkdirs()) return null
        var target = File(dir, name)
        // 同名不覆盖：`x (1).txt`、`x (2).txt`…
        if (target.exists()) {
            val dot = name.lastIndexOf('.')
            val stem = if (dot > 0) name.substring(0, dot) else name
            val ext = if (dot > 0) name.substring(dot) else ""
            var i = 1
            while (target.exists() && i < 1000) {
                target = File(dir, "$stem ($i)$ext")
                i++
            }
        }
        src.inputStream().use { input ->
            target.outputStream().use { out -> input.copyTo(out) }
        }
        return Uri.fromFile(target).toString()
    }
}
